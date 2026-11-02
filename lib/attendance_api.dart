import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

abstract interface class AttendanceService {
  bool get isConfigured;

  String? get configurationError;

  Future<String?> readToken();

  Future<void> saveToken(String token);

  Future<void> clearToken();

  Future<String> authenticate(String password);

  Future<TimeRecord?> loadToday(String token, String date);

  Future<List<TimeRecord>> loadHistory(String token);

  Future<TimeRecord> recordPunch(
    String token,
    String date, {
    required bool isTimeIn,
  });
}

class AttendanceApi implements AttendanceService {
  const AttendanceApi();

  static const _baseUrl = String.fromEnvironment('SYNC_API_BASE_URL');
  static const _tokenKey = 'sync.accessToken';
  static const _tokenStorage = FlutterSecureStorage();
  static const _requestTimeout = Duration(seconds: 15);

  Uri get _apiBase {
    final uri = Uri.tryParse(_baseUrl);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        (uri.path.isNotEmpty && uri.path != '/') ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const AttendanceApiException(
        'The SYNC API URL is not configured. Build the app with '
        '--dart-define=SYNC_API_BASE_URL=https://your-backend.example.com.',
      );
    }
    return uri;
  }

  @override
  bool get isConfigured {
    try {
      _apiBase;
      return true;
    } on AttendanceApiException {
      return false;
    }
  }

  @override
  String? get configurationError {
    try {
      _apiBase;
      return null;
    } on AttendanceApiException catch (error) {
      return error.message;
    }
  }

  @override
  Future<String?> readToken() => _tokenStorage.read(key: _tokenKey);

  @override
  Future<void> saveToken(String token) =>
      _tokenStorage.write(key: _tokenKey, value: token);

  @override
  Future<void> clearToken() => _tokenStorage.delete(key: _tokenKey);

  @override
  Future<String> authenticate(String password) async {
    final body = await _send(
      'POST',
      '/api/auth/login',
      jsonBody: {'password': password},
    );
    final token = body['token'];
    if (token is! String || token.isEmpty) {
      throw const AttendanceApiException(
        'The server did not return a valid sign-in session.',
      );
    }
    return token;
  }

  @override
  Future<TimeRecord?> loadToday(String token, String date) async {
    final body = await _send(
      'GET',
      '/api/attendance/today',
      token: token,
      query: {'date': date},
    );
    final record = body['record'];
    if (record == null) return null;
    if (record is! Map<String, dynamic>) {
      throw const AttendanceApiException(
        'The server returned an invalid attendance record.',
      );
    }

    final parsed = TimeRecord.fromJson(record);
    if (parsed.date != date) {
      throw const AttendanceApiException(
        'The server returned a record for the wrong date.',
      );
    }
    return parsed;
  }

  @override
  Future<List<TimeRecord>> loadHistory(String token) async {
    final body = await _send('GET', '/api/attendance', token: token);
    final records = body['records'];
    if (records is! List) {
      throw const AttendanceApiException(
        'The server returned an invalid attendance history.',
      );
    }

    return records
        .map((record) {
          if (record is! Map<String, dynamic>) {
            throw const AttendanceApiException(
              'The server returned an invalid attendance record.',
            );
          }
          return TimeRecord.fromJson(record);
        })
        .toList(growable: false);
  }

  @override
  Future<TimeRecord> recordPunch(
    String token,
    String date, {
    required bool isTimeIn,
  }) async {
    final body = await _send(
      'POST',
      isTimeIn ? '/api/attendance/time-in' : '/api/attendance/time-out',
      token: token,
      jsonBody: {'date': date},
    );
    final record = body['record'];
    if (record is! Map<String, dynamic>) {
      throw const AttendanceApiException(
        'The server did not return the saved attendance record.',
      );
    }
    final parsed = TimeRecord.fromJson(record);
    if (parsed.date != date ||
        (isTimeIn && parsed.timeIn == null) ||
        (!isTimeIn && parsed.timeOut == null)) {
      throw const AttendanceApiException(
        'The server returned an invalid saved attendance record.',
      );
    }
    return parsed;
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    String? token,
    Map<String, String>? query,
    Map<String, Object?>? jsonBody,
  }) async {
    final uri = _apiBase.resolve(path).replace(queryParameters: query);
    final headers = <String, String>{'Accept': 'application/json'};
    if (token != null) headers['Authorization'] = 'Bearer $token';
    if (jsonBody != null) headers['Content-Type'] = 'application/json';

    try {
      final response = switch (method) {
        'GET' => await http.get(uri, headers: headers).timeout(_requestTimeout),
        'POST' =>
          await http
              .post(uri, headers: headers, body: jsonEncode(jsonBody))
              .timeout(_requestTimeout),
        _ => throw ArgumentError.value(method, 'method'),
      };

      final body = _decodeBody(response.body);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final message = body['error'];
        throw AttendanceApiException(
          message is String ? message : 'The server rejected the request.',
          statusCode: response.statusCode,
        );
      }
      return body;
    } on TimeoutException {
      throw const AttendanceApiException(
        'The server took too long to respond. Check your connection and try again.',
      );
    } on http.ClientException {
      throw const AttendanceApiException(
        'Could not reach the SYNC server. Check your internet connection and server URL.',
      );
    }
  }

  Map<String, dynamic> _decodeBody(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      throw const AttendanceApiException(
        'The server returned an unreadable response.',
      );
    }
    throw const AttendanceApiException(
      'The server returned an unreadable response.',
    );
  }
}

class AttendanceApiException implements Exception {
  const AttendanceApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class TimeRecord {
  const TimeRecord({required this.date, this.timeIn, this.timeOut});

  factory TimeRecord.empty(String date) => TimeRecord(date: date);

  factory TimeRecord.fromJson(Map<String, dynamic> json) {
    final date = json['date'];
    if (date is! String || !_isDateKey(date)) {
      throw const FormatException('The saved date is invalid.');
    }

    final timeIn = _parseTime(json['timeIn'], 'time in');
    final timeOut = _parseTime(json['timeOut'], 'time out');
    if (timeOut != null && timeIn == null) {
      throw const FormatException('Time out exists without a time in.');
    }
    return TimeRecord(date: date, timeIn: timeIn, timeOut: timeOut);
  }

  final String date;
  final DateTime? timeIn;
  final DateTime? timeOut;

  Map<String, Object?> toJson() => {
    'date': date,
    'timeIn': timeIn?.toIso8601String(),
    'timeOut': timeOut?.toIso8601String(),
  };

  static DateTime? _parseTime(Object? value, String label) {
    if (value == null) return null;
    if (value is! String) {
      throw FormatException('The saved $label is invalid.');
    }
    final parsed = DateTime.tryParse(value);
    if (parsed == null) {
      throw FormatException('The saved $label is invalid.');
    }
    return parsed.toLocal();
  }
}

String dateKeyFor(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

bool _isDateKey(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
  final parsed = DateTime.tryParse(value);
  return parsed != null && dateKeyFor(parsed) == value;
}
