import 'dart:async';

import 'package:demo_app/attendance_api.dart';
import 'package:flutter/material.dart';

void main() {
  runApp(const SyncApp());
}

class SyncApp extends StatelessWidget {
  const SyncApp({super.key, this.api = const AttendanceApi()});

  final AttendanceService api;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SYNC',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B0D10),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF56C5DE),
          brightness: Brightness.dark,
        ),
      ),
      home: SyncHomePage(api: api),
    );
  }
}

class SyncHomePage extends StatefulWidget {
  const SyncHomePage({super.key, required this.api});

  final AttendanceService api;

  @override
  State<SyncHomePage> createState() => _SyncHomePageState();
}

class _SyncHomePageState extends State<SyncHomePage>
    with WidgetsBindingObserver {
  late DateTime _today;
  late TimeRecord _record;
  Timer? _dayChangeTimer;
  String? _token;
  String? _loadError;
  String? _historyError;
  List<TimeRecord> _history = const [];
  int _selectedTab = 0;
  bool _isLoading = true;
  bool _isHistoryLoading = false;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _today = DateTime.now();
    _record = TimeRecord.empty(dateKeyFor(_today));
    WidgetsBinding.instance.addObserver(this);
    unawaited(_restoreSession());
    _dayChangeTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _refreshForNewDay(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refreshForNewDay();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dayChangeTimer?.cancel();
    super.dispose();
  }

  Future<void> _restoreSession() async {
    if (!widget.api.isConfigured) {
      setState(() {
        _isLoading = false;
        _loadError = widget.api.configurationError;
      });
      return;
    }

    try {
      final token = await widget.api.readToken();
      if (!mounted) return;
      if (token == null) {
        setState(() => _isLoading = false);
        return;
      }
      setState(() => _token = token);
      await _loadRecord();
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _loadError = 'Could not restore the saved session: $error';
      });
    }
  }

  Future<void> _loadRecord() async {
    final token = _token;
    if (token == null) {
      if (mounted) setState(() => _isLoading = false);
      return;
    }

    final requestedDate = dateKeyFor(_today);
    if (mounted) {
      setState(() {
        _isLoading = true;
        _loadError = null;
      });
    }
    try {
      final record = await widget.api.loadToday(token, requestedDate);
      if (!mounted || requestedDate != dateKeyFor(_today)) return;
      setState(() {
        _record = record ?? TimeRecord.empty(requestedDate);
        _isLoading = false;
        _loadError = null;
      });
    } on Exception catch (error) {
      if (!mounted) return;
      if (error is AttendanceApiException && error.statusCode == 401) {
        await _expireSession();
        return;
      }
      setState(() {
        _isLoading = false;
        _loadError = 'Could not load today\'s time records: $error';
      });
    }
  }

  void _refreshForNewDay() {
    final currentDate = DateTime.now();
    if (dateKeyFor(currentDate) == dateKeyFor(_today)) return;

    setState(() {
      _today = currentDate;
      _record = TimeRecord.empty(dateKeyFor(currentDate));
      _isLoading = _token != null;
      _loadError = null;
    });
    if (_token != null) unawaited(_loadRecord());
  }

  Future<String?> _requestPassword() async {
    if (!widget.api.isConfigured) {
      _showMessage(
        widget.api.configurationError ?? 'The API is not configured.',
      );
      return null;
    }

    final token = await showDialog<String>(
      context: context,
      builder: (context) => _PasswordDialog(
        onSubmit: (password) async {
          final token = await widget.api.authenticate(password);
          await widget.api.saveToken(token);
          return token;
        },
      ),
    );
    if (!mounted || token == null) return null;
    setState(() {
      _token = token;
      _loadError = null;
    });
    return token;
  }

  Future<void> _recordTime({required bool isTimeIn}) async {
    if (_isLoading || _isSaving) return;
    if (_token != null && _loadError != null) return;

    var token = _token;
    if (token == null) {
      token = await _requestPassword();
      if (token == null) return;
      await _loadRecord();
      if (!mounted || _loadError != null || _token == null) return;
      token = _token!;
    }
    if (isTimeIn && _record.timeIn != null) return;
    if (!isTimeIn && (_record.timeIn == null || _record.timeOut != null)) {
      return;
    }

    setState(() => _isSaving = true);
    try {
      final updatedRecord = await widget.api.recordPunch(
        token,
        dateKeyFor(_today),
        isTimeIn: isTimeIn,
      );
      if (!mounted) return;
      setState(() {
        _record = updatedRecord;
        _isSaving = false;
      });
    } on Exception catch (error) {
      if (!mounted) return;
      if (error is AttendanceApiException && error.statusCode == 401) {
        await _expireSession();
        return;
      }
      if (error is AttendanceApiException && error.statusCode == 409) {
        setState(() => _isSaving = false);
        await _loadRecord();
        return;
      }
      setState(() => _isSaving = false);
      _showMessage('Could not save your time to MongoDB: $error');
    }
  }

  Future<void> _openStorage() async {
    if (_isSaving || _isHistoryLoading) return;
    final token = await _requestPassword();
    if (!mounted || token == null) return;
    setState(() {
      _selectedTab = 1;
      _isHistoryLoading = true;
      _historyError = null;
    });
    await _loadRecord();
    if (!mounted || _token == null) return;
    await _loadHistory(token);
  }

  Future<void> _loadHistory(String token) async {
    setState(() {
      _isHistoryLoading = true;
      _historyError = null;
    });
    try {
      final records = await widget.api.loadHistory(token);
      if (!mounted) return;
      setState(() {
        _history = records;
        _isHistoryLoading = false;
      });
    } on Exception catch (error) {
      if (!mounted) return;
      if (error is AttendanceApiException && error.statusCode == 401) {
        await _expireSession();
        return;
      }
      setState(() {
        _isHistoryLoading = false;
        _historyError = 'Could not load attendance history: $error';
      });
    }
  }

  Future<void> _expireSession() async {
    try {
      await widget.api.clearToken();
      if (!mounted) return;
      setState(() {
        _token = null;
        _record = TimeRecord.empty(dateKeyFor(_today));
        _history = const [];
        _selectedTab = 0;
        _isLoading = false;
        _isSaving = false;
        _isHistoryLoading = false;
        _loadError = null;
      });
      _showMessage(
        'Your API session expired. Enter your password to continue.',
      );
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _token = null;
        _selectedTab = 0;
        _isLoading = false;
        _isSaving = false;
        _isHistoryLoading = false;
        _loadError = 'The expired session could not be cleared: $error';
      });
    }
  }

  Future<void> _retryLoading() async {
    if (_token != null) await _loadRecord();
  }

  void _selectTab(int index) {
    Navigator.pop(context);
    if (index == 1) {
      unawaited(_openStorage());
      return;
    }
    setState(() => _selectedTab = 0);
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_selectedTab == 0 ? 'Toggle' : 'Storage'),
        backgroundColor: const Color(0xFF0B0D10),
      ),
      drawer: Drawer(
        backgroundColor: const Color(0xFF11151A),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DrawerHeader(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(14),
                      child: Image.asset(
                        'images/LOGO.jpg',
                        width: 72,
                        height: 72,
                        fit: BoxFit.cover,
                        semanticLabel: 'SYNC logo',
                      ),
                    ),
                    const Spacer(),
                    Text(
                      'SYNC',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        letterSpacing: 2,
                      ),
                    ),
                  ],
                ),
              ),
              ListTile(
                key: const ValueKey('nav-toggle'),
                selected: _selectedTab == 0,
                leading: const Icon(Icons.toggle_on_rounded),
                title: const Text('Toggle'),
                onTap: () => _selectTab(0),
              ),
              ListTile(
                key: const ValueKey('nav-storage'),
                selected: _selectedTab == 1,
                leading: const Icon(Icons.storage_rounded),
                title: const Text('Storage'),
                subtitle: const Text('Password required'),
                onTap: () => _selectTab(1),
              ),
            ],
          ),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: _selectedTab == 0
                ? _buildToggle(context)
                : _buildStorage(context),
          ),
        ),
      ),
    );
  }

  Widget _buildToggle(BuildContext context) {
    final timeInRecorded = _record.timeIn != null;
    final timeOutRecorded = _record.timeOut != null;
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
      children: [
        _buildHeader(context),
        const SizedBox(height: 28),
        _buildDateCard(context),
        const SizedBox(height: 20),
        if (_loadError case final error?) _buildLoadError(context, error),
        _TimePunchCard(
          title: 'Time In',
          description: timeInRecorded
              ? 'You started your day at'
              : 'Tap to record when you start work',
          time: _record.timeIn,
          isRecorded: timeInRecorded,
          isEnabled: !_isLoading && !_isSaving && _loadError == null,
          isSaving: _isSaving && !timeInRecorded,
          icon: Icons.login_rounded,
          accent: const Color(0xFF56C5DE),
          actionLabel: 'Clock In',
          onPressed: () => _recordTime(isTimeIn: true),
        ),
        const SizedBox(height: 16),
        _TimePunchCard(
          title: 'Time Out',
          description: timeOutRecorded
              ? 'You finished your day at'
              : timeInRecorded
              ? 'Tap to record when you finish work'
              : 'Available after you record Time In',
          time: _record.timeOut,
          isRecorded: timeOutRecorded,
          isEnabled:
              timeInRecorded && !_isLoading && !_isSaving && _loadError == null,
          isSaving: _isSaving && timeInRecorded && !timeOutRecorded,
          icon: Icons.logout_rounded,
          accent: const Color(0xFFA994F5),
          actionLabel: 'Clock Out',
          onPressed: () => _recordTime(isTimeIn: false),
        ),
        if (_isLoading) ...[
          const SizedBox(height: 20),
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ],
        const SizedBox(height: 24),
        Text(
          'Your time records are saved securely to MongoDB.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall
              ?.copyWith(color: const Color(0xFF777F88)),
        ),
      ],
    );
  }

  Widget _buildStorage(BuildContext context) {
    return ListView(
      key: const ValueKey('storage-page'),
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
      children: [
        Text(
          'Attendance history',
          style: Theme.of(context).textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          'Your saved Time In and Time Out records.',
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: const Color(0xFF9AA2AA)),
        ),
        const SizedBox(height: 20),
        if (_isHistoryLoading)
          const Center(
            child: Padding(
              padding: EdgeInsets.all(28),
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else if (_historyError case final error?)
          _buildHistoryError(context, error)
        else if (_history.isEmpty)
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: const Color(0xFF15191E),
              borderRadius: BorderRadius.circular(18),
            ),
            child: const Text(
              'No attendance records yet. Your saved times will appear here.',
              textAlign: TextAlign.center,
            ),
          )
        else
          for (final record in _history) _buildHistoryCard(context, record),
      ],
    );
  }

  Widget _buildHistoryCard(BuildContext context, TimeRecord record) {
    final date = DateTime.parse(record.date);
    return Container(
      key: ValueKey('history-${record.date}'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF15191E),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_monthName(date.month)} ${date.day}, ${date.year}',
            style: Theme.of(context).textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _historyTime(
                  context,
                  'TIME IN',
                  record.timeIn,
                  const Color(0xFF56C5DE),
                ),
              ),
              Expanded(
                child: _historyTime(
                  context,
                  'TIME OUT',
                  record.timeOut,
                  const Color(0xFFA994F5),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _historyTime(
    BuildContext context,
    String label,
    DateTime? value,
    Color color,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall
              ?.copyWith(color: const Color(0xFF939BA3), letterSpacing: 1),
        ),
        const SizedBox(height: 4),
        Text(
          value == null ? '—' : TimeOfDay.fromDateTime(value).format(context),
          style: Theme.of(context).textTheme.titleMedium
              ?.copyWith(color: color, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  Widget _buildHistoryError(BuildContext context, String error) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF321D20),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(error),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _token == null ? null : () => _loadHistory(_token!),
            child: const Text('Try again'),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 88,
          height: 94,
          decoration: BoxDecoration(
            color: const Color(0xFF15191E),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          clipBehavior: Clip.antiAlias,
          child: Image.asset(
            'images/LOGO.jpg',
            fit: BoxFit.cover,
            semanticLabel: 'SYNC logo',
          ),
        ),
        const SizedBox(width: 18),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'SYNC',
                style: Theme.of(context).textTheme.headlineSmall
                    ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 2.4),
              ),
              const SizedBox(height: 5),
              Text(
                'TIME TRACKER',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: const Color(0xFF9AA2AA),
                  letterSpacing: 1.8,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'Your day, at a glance.',
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: const Color(0xFF777F88)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDateCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF15191E),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        children: [
          const Icon(Icons.calendar_today_rounded, size: 19),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              '${_weekdayName(_today.weekday)}, ${_monthName(_today.month)} ${_today.day}',
              style: Theme.of(context).textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          Text(
            'TODAY',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: const Color(0xFF56C5DE),
              letterSpacing: 1.4,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadError(BuildContext context, String error) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF321D20),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(error, style: Theme.of(context).textTheme.bodyMedium),
          if (_token != null) ...[
            const SizedBox(height: 8),
            TextButton(
              onPressed: _isLoading ? null : _retryLoading,
              child: const Text('Try again'),
            ),
          ],
        ],
      ),
    );
  }
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({required this.onSubmit});

  final Future<String> Function(String password) onSubmit;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _passwordController = TextEditingController();
  String? _errorMessage;
  bool _isBusy = false;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_isBusy || !_formKey.currentState!.validate()) return;
    setState(() {
      _isBusy = true;
      _errorMessage = null;
    });
    try {
      final token = await widget.onSubmit(_passwordController.text);
      if (mounted) Navigator.pop(context, token);
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _isBusy = false;
        _errorMessage = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Storage password'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('Enter your SYNC API password to view saved records.'),
            const SizedBox(height: 18),
            TextFormField(
              key: const ValueKey('storage-password'),
              controller: _passwordController,
              autofocus: true,
              enabled: !_isBusy,
              obscureText: true,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                labelText: 'Password',
                prefixIcon: Icon(Icons.lock_outline_rounded),
              ),
              validator: (value) => value == null || value.isEmpty
                  ? 'Enter your password.'
                  : null,
            ),
            if (_errorMessage case final error?) ...[
              const SizedBox(height: 12),
              Text(
                error,
                key: const ValueKey('password-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isBusy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _isBusy ? null : _submit,
          child: _isBusy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Continue'),
        ),
      ],
    );
  }
}

class _TimePunchCard extends StatelessWidget {
  const _TimePunchCard({
    required this.title,
    required this.description,
    required this.time,
    required this.isRecorded,
    required this.isEnabled,
    required this.isSaving,
    required this.icon,
    required this.accent,
    required this.actionLabel,
    required this.onPressed,
  });

  final String title;
  final String description;
  final DateTime? time;
  final bool isRecorded;
  final bool isEnabled;
  final bool isSaving;
  final IconData icon;
  final Color accent;
  final String actionLabel;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final recorded = time != null;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF15191E),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: recorded ? accent.withValues(alpha: 0.42) : Colors.white12,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: 0.13),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: accent),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleLarge
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      description,
                      style: Theme.of(context).textTheme.bodySmall
                          ?.copyWith(color: const Color(0xFF939BA3)),
                    ),
                  ],
                ),
              ),
              Icon(
                recorded ? Icons.check_circle_rounded : Icons.schedule_rounded,
                color: recorded ? accent : const Color(0xFF747C85),
                size: 22,
              ),
            ],
          ),
          if (time case final recordedTime?) ...[
            const SizedBox(height: 14),
            Text(
              TimeOfDay.fromDateTime(recordedTime).format(context),
              style: Theme.of(context).textTheme.headlineMedium
                  ?.copyWith(color: accent, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 2),
            Text(
              'RECORDED',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: const Color(0xFF939BA3),
                letterSpacing: 1.5,
              ),
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              key: ValueKey('button-$title'),
              onPressed: isEnabled && !recorded ? onPressed : null,
              style: FilledButton.styleFrom(
                backgroundColor: accent,
                foregroundColor: const Color(0xFF091014),
                disabledBackgroundColor: const Color(0xFF252A30),
                disabledForegroundColor: recorded
                    ? accent
                    : const Color(0xFF737B84),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              icon: isSaving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(recorded ? Icons.check_rounded : icon),
              label: Text(recorded ? 'Recorded' : actionLabel),
            ),
          ),
        ],
      ),
    );
  }
}

String _weekdayName(int weekday) => const [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
][weekday - 1];

String _monthName(int month) => const [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
][month - 1];
