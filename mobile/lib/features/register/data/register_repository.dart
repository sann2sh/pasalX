import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../../core/database/app_database.dart';
import '../../../core/database/money.dart';
import '../domain/register_models.dart';

/// Encrypted local repository for Single-Galla Cash Register, Staff Punch-Out
/// Checklist, Force-Close Override, and End-of-Day Z-Report settlement.
class RegisterRepository {
  RegisterRepository(this._db);

  final AppDatabase _db;
  static const Uuid _uuid = Uuid();

  static void _requireManagerOrOwner(String role, String action) {
    final normalized = role.trim().toUpperCase();
    if (normalized != 'OWNER' && normalized != 'MANAGER') {
      throw StateError('Permission denied ($normalized): $action requires OWNER or MANAGER.');
    }
  }

  /// Streams the active `OPEN` register shift, if one exists.
  Stream<RegisterShiftRow?> watchActiveShift() => _db.watchOpenRegisterShift();

  /// Fetches the most recently closed shift for Next-Day Float rollover.
  Future<RegisterShiftRow?> fetchLastClosedShift() {
    final query = _db.select(_db.registerShifts)
      ..where((t) => t.status.equals('CLOSED'))
      ..orderBy([(t) => OrderingTerm.desc(t.closedAt)])
      ..limit(1);
    return query.getSingleOrNull();
  }

  /// Streams the most recently closed shift for post-close summary display.
  Stream<RegisterShiftRow?> watchLastClosedShift() {
    final query = _db.select(_db.registerShifts)
      ..where((t) => t.status.equals('CLOSED'))
      ..orderBy([(t) => OrderingTerm.desc(t.closedAt)])
      ..limit(1);
    return query.watchSingleOrNull();
  }

  /// Streams all staff sessions for [shiftId] joined with `users` display names.
  Stream<List<StaffSessionWithUser>> watchStaffSessionsForShift(
    String shiftId,
  ) {
    final query = _db.select(_db.staffShiftSessions).join([
      leftOuterJoin(
        _db.users,
        _db.users.id.equalsExp(_db.staffShiftSessions.userId),
      ),
    ])
      ..where(_db.staffShiftSessions.registerShiftId.equals(shiftId))
      ..orderBy([OrderingTerm.asc(_db.staffShiftSessions.punchedInAt)]);

    return query.watch().map((rows) {
      return rows.map((row) {
        final sess = row.readTable(_db.staffShiftSessions);
        final user = row.readTableOrNull(_db.users);
        return StaffSessionWithUser(
          session: sess,
          displayName: user?.name ?? 'Staff (${sess.deviceCode})',
          role: user?.role ?? 'STAFF',
        );
      }).toList(growable: false);
    });
  }

  /// Marks the active terminal session(s) for [userId] + [deviceCode] as
  /// `PUNCHED_OUT` and enqueues `staff_shift_sessions` UPDATE into `sync_outbox`.
  Future<StaffShiftSessionRow> punchOutCurrentStaff({
    required String shiftId,
    required String userId,
    required String deviceCode,
  }) async {
    final now = DateTime.now().toUtc();

    return _db.transaction(() async {
      final activeRows = await (_db.select(_db.staffShiftSessions)
            ..where(
              (t) =>
                  t.registerShiftId.equals(shiftId) &
                  t.userId.equals(userId) &
                  t.deviceCode.equals(deviceCode) &
                  t.status.equals('ACTIVE'),
            )
            ..orderBy([(t) => OrderingTerm.desc(t.punchedInAt)]))
          .get();
      if (activeRows.isEmpty) {
        throw StateError('No active staff punch-in session found for this terminal.');
      }

      for (final sess in activeRows) {
        await (_db.update(_db.staffShiftSessions)
              ..where((t) => t.id.equals(sess.id)))
            .write(
          StaffShiftSessionsCompanion(
            status: const Value('PUNCHED_OUT'),
            punchedOutAt: Value(now),
            lastSyncedAt: Value(now),
            updatedAt: Value(now),
          ),
        );

        final payload = <String, dynamic>{
          'id': sess.id,
          'register_shift_id': sess.registerShiftId,
          'user_id': sess.userId,
          'device_code': sess.deviceCode,
          'punched_in_at': sess.punchedInAt.toUtc().toIso8601String(),
          'punched_out_at': now.toIso8601String(),
          'last_synced_at': now.toIso8601String(),
          'status': 'PUNCHED_OUT',
          'updated_at': now.toIso8601String(),
        };

        await _db.enqueueOutboxMutation(
          mutationId: _uuid.v4(),
          targetTable: 'staff_shift_sessions',
          recordId: sess.id,
          operation: 'UPDATE',
          payloadJson: jsonEncode(payload),
          clientUpdatedAt: now,
          createdAt: now,
        );
      }

      return (_db.select(_db.staffShiftSessions)
            ..where((t) => t.id.equals(activeRows.first.id)))
          .getSingle();
    });
  }

  /// Manager/Owner override to force-close a missing or offline staff phone's
  /// active session (`FORCE_CLOSED`) so nightly Z-Report is never deadlocked.
  Future<StaffShiftSessionRow> forceCloseStaffSession({
    required String sessionId,
    required String managerUserId,
    required String managerRole,
  }) async {
    _requireManagerOrOwner(managerRole, 'Force Punch-Out');
    final now = DateTime.now().toUtc();
    final mutId = _uuid.v4();

    return _db.transaction(() async {
      final sess = await (_db.select(_db.staffShiftSessions)
            ..where((t) => t.id.equals(sessionId)))
          .getSingleOrNull();
      if (sess == null) {
        throw StateError('Staff shift session not found.');
      }
      if (sess.status != 'ACTIVE') {
        return sess;
      }

      await (_db.update(_db.staffShiftSessions)
            ..where((t) => t.id.equals(sessionId)))
          .write(
        StaffShiftSessionsCompanion(
          status: const Value('FORCE_CLOSED'),
          punchedOutAt: Value(now),
          forceClosedByUserId: Value(managerUserId),
          updatedAt: Value(now),
        ),
      );

      final payload = <String, dynamic>{
        'id': sess.id,
        'register_shift_id': sess.registerShiftId,
        'user_id': sess.userId,
        'device_code': sess.deviceCode,
        'punched_in_at': sess.punchedInAt.toUtc().toIso8601String(),
        'punched_out_at': now.toIso8601String(),
        'last_synced_at': sess.lastSyncedAt.toUtc().toIso8601String(),
        'status': 'FORCE_CLOSED',
        'force_closed_by_user_id': managerUserId,
        'updated_at': now.toIso8601String(),
      };

      await _db.enqueueOutboxMutation(
        mutationId: mutId,
        targetTable: 'staff_shift_sessions',
        recordId: sess.id,
        operation: 'UPDATE',
        payloadJson: jsonEncode(payload),
        clientUpdatedAt: now,
        createdAt: now,
      );

      return (_db.select(_db.staffShiftSessions)
            ..where((t) => t.id.equals(sessionId)))
          .getSingle();
    });
  }

  /// Settles and closes the Single-Galla [shiftId] with Bank Drop & Next-Day
  /// Float carryover. Enforces that zero `ACTIVE` staff sessions remain.
  Future<RegisterShiftRow> closeShiftAndGenerateZReport({
    required String shiftId,
    required String closedByUserId,
    required String closedByRole,
    required int actualCashCountedPaisa,
    required int cashWithdrawnDepositPaisa,
    required int retainedNextDayFloatPaisa,
    String? notes,
  }) async {
    _requireManagerOrOwner(closedByRole, 'Settle Z-Report');
    if (actualCashCountedPaisa < 0 ||
        actualCashCountedPaisa > MoneyUtils.maxDecimal10_2Paisa) {
      throw ArgumentError('Actual cash counted must be non-negative.');
    }
    if (cashWithdrawnDepositPaisa < 0 || retainedNextDayFloatPaisa < 0) {
      throw ArgumentError('Bank drop and retained float must be non-negative.');
    }
    if (cashWithdrawnDepositPaisa + retainedNextDayFloatPaisa !=
        actualCashCountedPaisa) {
      throw ArgumentError(
        'Bank drop (${MoneyUtils.formatRs(cashWithdrawnDepositPaisa)}) + '
        'Next-day float (${MoneyUtils.formatRs(retainedNextDayFloatPaisa)}) '
        'must equal actual cash counted (${MoneyUtils.formatRs(actualCashCountedPaisa)}).',
      );
    }

    final now = DateTime.now().toUtc();
    final mutId = _uuid.v4();
    final cleanNotes =
        (notes != null && notes.trim().isNotEmpty) ? notes.trim() : null;

    return _db.transaction(() async {
      final shift = await (_db.select(_db.registerShifts)
            ..where((t) => t.id.equals(shiftId)))
          .getSingleOrNull();
      if (shift == null) {
        throw StateError('Register shift not found.');
      }
      if (shift.status != 'OPEN') {
        throw StateError('Register shift is already closed.');
      }

      final activeSessions = await (_db.select(_db.staffShiftSessions)
            ..where(
              (t) =>
                  t.registerShiftId.equals(shiftId) & t.status.equals('ACTIVE'),
            ))
          .get();
      if (activeSessions.isNotEmpty) {
        throw StateError(
          '${activeSessions.length} staff terminal(s) still ACTIVE. '
          'Punch out or Force Close all staff before settling Z-Report.',
        );
      }

      final discrepancyPaisa = actualCashCountedPaisa - shift.expectedCash;
      if (discrepancyPaisa.abs() > MoneyUtils.maxDecimal10_2Paisa) {
        throw ArgumentError('Cash discrepancy exceeds DECIMAL(10,2) limits.');
      }

      await (_db.update(_db.registerShifts)
            ..where((t) => t.id.equals(shiftId)))
          .write(
        RegisterShiftsCompanion(
          closedByUserId: Value(closedByUserId),
          closedAt: Value(now),
          actualCashCounted: Value(actualCashCountedPaisa),
          discrepancy: Value(discrepancyPaisa),
          cashWithdrawnDeposit: Value(cashWithdrawnDepositPaisa),
          retainedNextDayFloat: Value(retainedNextDayFloatPaisa),
          status: const Value('CLOSED'),
          notes: Value(cleanNotes),
          updatedAt: Value(now),
        ),
      );

      final closed = await (_db.select(_db.registerShifts)
            ..where((t) => t.id.equals(shiftId)))
          .getSingle();

      final payload = <String, dynamic>{
        'id': closed.id,
        'opened_by_user_id': closed.openedByUserId,
        'closed_by_user_id': closedByUserId,
        'opened_at': closed.openedAt.toUtc().toIso8601String(),
        'closed_at': now.toIso8601String(),
        'opening_float': MoneyUtils.toDecimalString(closed.openingFloat),
        'cash_sales': MoneyUtils.toDecimalString(closed.cashSales),
        'digital_sales': MoneyUtils.toDecimalString(closed.digitalSales),
        'khata_cash_repayments':
            MoneyUtils.toDecimalString(closed.khataCashRepayments),
        'cash_expenses': MoneyUtils.toDecimalString(closed.cashExpenses),
        'expected_cash': MoneyUtils.toDecimalString(closed.expectedCash),
        'actual_cash_counted':
            MoneyUtils.toDecimalString(actualCashCountedPaisa),
        'discrepancy': MoneyUtils.toDecimalString(discrepancyPaisa),
        'cash_withdrawn_deposit':
            MoneyUtils.toDecimalString(cashWithdrawnDepositPaisa),
        'retained_next_day_float':
            MoneyUtils.toDecimalString(retainedNextDayFloatPaisa),
        'status': 'CLOSED',
        if (cleanNotes != null) 'notes': cleanNotes,
        'created_at': closed.createdAt.toUtc().toIso8601String(),
        'updated_at': now.toIso8601String(),
      };

      await _db.enqueueOutboxMutation(
        mutationId: mutId,
        targetTable: 'register_shifts',
        recordId: closed.id,
        operation: 'UPDATE',
        payloadJson: jsonEncode(payload),
        clientUpdatedAt: now,
        createdAt: now,
      );

      return closed;
    });
  }
}

