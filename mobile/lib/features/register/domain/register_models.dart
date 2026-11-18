import 'package:flutter/foundation.dart';

import '../../../core/database/app_database.dart';

@immutable
class StaffSessionWithUser {
  const StaffSessionWithUser({
    required this.session,
    required this.displayName,
    required this.role,
  });

  final StaffShiftSessionRow session;
  final String displayName;
  final String role;

  bool get isActive => session.status == 'ACTIVE';
  bool get isPunchedOut => session.status == 'PUNCHED_OUT';
  bool get isForceClosed => session.status == 'FORCE_CLOSED';
}

@immutable
class ZReportSettlementResult {
  const ZReportSettlementResult({
    required this.closedShift,
    required this.discrepancyPaisa,
    this.receiptBytes,
  });

  final RegisterShiftRow closedShift;
  final int discrepancyPaisa;
  final Uint8List? receiptBytes;
}

