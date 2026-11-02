import 'package:demo_app/attendance_api.dart';
import 'package:demo_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeAttendanceService implements AttendanceService {
  final Map<String, TimeRecord> records = {};
  String? savedToken;

  @override
  bool get isConfigured => true;

  @override
  String? get configurationError => null;

  @override
  Future<String?> readToken() async => savedToken;

  @override
  Future<void> saveToken(String token) async {
    savedToken = token;
  }

  @override
  Future<void> clearToken() async {
    savedToken = null;
  }

  @override
  Future<String> authenticate(String password) async {
    if (password != 'password') {
      throw const AttendanceApiException(
        'Incorrect password.',
        statusCode: 401,
      );
    }
    return 'test-token';
  }

  @override
  Future<TimeRecord?> loadToday(String token, String date) async =>
      records[date];

  @override
  Future<List<TimeRecord>> loadHistory(String token) async {
    final history = records.values.toList()
      ..sort((left, right) => right.date.compareTo(left.date));
    return history;
  }

  @override
  Future<TimeRecord> recordPunch(
    String token,
    String date, {
    required bool isTimeIn,
  }) async {
    final existing = records[date] ?? TimeRecord.empty(date);
    if (isTimeIn && existing.timeIn != null) {
      throw const AttendanceApiException(
        'Time In is already recorded for today.',
        statusCode: 409,
      );
    }
    if (!isTimeIn && existing.timeIn == null) {
      throw const AttendanceApiException(
        'Record Time In before recording Time Out.',
        statusCode: 409,
      );
    }
    if (!isTimeIn && existing.timeOut != null) {
      throw const AttendanceApiException(
        'Time Out is already recorded for today.',
        statusCode: 409,
      );
    }

    final now = DateTime.now();
    final updated = TimeRecord(
      date: date,
      timeIn: isTimeIn ? now : existing.timeIn,
      timeOut: isTimeIn ? existing.timeOut : now,
    );
    records[date] = updated;
    return updated;
  }
}

Future<void> _enterPassword(WidgetTester tester) async {
  await tester.enterText(
    find.byKey(const ValueKey('storage-password')),
    'password',
  );
  await tester.tap(find.text('Continue'));
  await tester.pumpAndSettle();
}

Future<void> _openStorage(WidgetTester tester) async {
  await tester.tap(find.byTooltip('Open navigation menu'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('nav-storage')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('opens Toggle directly and records time in before time out', (
    WidgetTester tester,
  ) async {
    final api = _FakeAttendanceService();
    await tester.pumpWidget(SyncApp(api: api));
    await tester.pumpAndSettle();

    expect(find.text('Toggle'), findsOneWidget);
    expect(find.text('Sign in to your time tracker'), findsNothing);
    expect(find.text('Clock In'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('button-Time Out')))
          .onPressed,
      isNull,
    );

    await tester.ensureVisible(find.text('Clock In'));
    await tester.tap(find.text('Clock In'));
    await tester.pumpAndSettle();
    await _enterPassword(tester);

    expect(find.text('RECORDED'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const ValueKey('button-Time Out')))
          .onPressed,
      isNotNull,
    );

    await tester.ensureVisible(find.text('Clock Out'));
    await tester.tap(find.text('Clock Out'));
    await tester.pumpAndSettle();

    expect(find.text('RECORDED'), findsNWidgets(2));
    expect(find.text('Clock In'), findsNothing);
    expect(find.text('Clock Out'), findsNothing);
  });

  testWidgets('Storage requires password and shows saved records', (
    WidgetTester tester,
  ) async {
    final api = _FakeAttendanceService();
    api.records['2026-11-02'] = TimeRecord(
      date: '2026-11-02',
      timeIn: DateTime(2026, 11, 2, 8),
      timeOut: DateTime(2026, 11, 2, 17),
    );

    await tester.pumpWidget(SyncApp(api: api));
    await tester.pumpAndSettle();
    await _openStorage(tester);

    expect(find.byKey(const ValueKey('storage-password')), findsOneWidget);
    expect(find.byKey(const ValueKey('storage-page')), findsNothing);

    await _enterPassword(tester);

    expect(find.byKey(const ValueKey('storage-page')), findsOneWidget);
    expect(find.text('November 2, 2026'), findsOneWidget);
    expect(find.text('8:00 AM'), findsOneWidget);
    expect(find.text('5:00 PM'), findsOneWidget);
  });

  testWidgets('restores today\'s records without a launch sign-in screen', (
    WidgetTester tester,
  ) async {
    final now = DateTime.now();
    final date = dateKeyFor(now);
    final api = _FakeAttendanceService()
      ..savedToken = 'test-token'
      ..records[date] = TimeRecord(
        date: date,
        timeIn: DateTime(now.year, now.month, now.day, 8),
        timeOut: DateTime(now.year, now.month, now.day, 17),
      );

    await tester.pumpWidget(SyncApp(api: api));
    await tester.pumpAndSettle();

    expect(find.text('RECORDED'), findsNWidgets(2));
    expect(find.text('Clock In'), findsNothing);
    expect(find.text('Clock Out'), findsNothing);
    expect(find.bySemanticsLabel('SYNC logo'), findsOneWidget);
  });
}
