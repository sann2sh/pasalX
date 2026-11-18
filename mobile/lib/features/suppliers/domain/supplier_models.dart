import 'package:flutter/foundation.dart';

import '../../../core/database/app_database.dart';

/// Supported supplier payment methods matching Go `allowedSupPayMethods`.
abstract final class SupplierPaymentMethods {
  static const String cash = 'CASH';
  static const String bankTransfer = 'BANK_TRANSFER';
  static const String fonepay = 'FONEPAY';
  static const String cheque = 'CHEQUE';

  static const List<String> all = <String>[
    cash,
    bankTransfer,
    fonepay,
    cheque,
  ];

  static String label(String method) {
    return switch (method) {
      cash => 'Cash',
      bankTransfer => 'Bank Transfer',
      fonepay => 'Fonepay',
      cheque => 'Cheque',
      _ => method,
    };
  }
}

/// Supported petty cash expense methods matching Go `allowedExpenseMethods`.
abstract final class ExpensePaymentMethods {
  static const String cash = 'CASH';
  static const String fonepay = 'FONEPAY';
  static const String bank = 'BANK';

  static const List<String> all = <String>[
    cash,
    fonepay,
    bank,
  ];

  static String label(String method) {
    return switch (method) {
      cash => 'Cash (Galla)',
      fonepay => 'Fonepay',
      bank => 'Bank',
      _ => method,
    };
  }
}

/// Common retail petty cash expense categories.
abstract final class ExpenseCategories {
  static const List<String> presets = <String>[
    'Tea & Snacks',
    'Courier / Delivery',
    'Packaging & Bags',
    'Cleaning & Supplies',
    'Transport',
    'Utilities / Misc',
  ];
}

@immutable
class SupplierDetailBundle {
  const SupplierDetailBundle({
    required this.supplier,
    required this.invoices,
    required this.payments,
  });

  final SupplierRow supplier;
  final List<PurchaseInvoiceRow> invoices;
  final List<SupplierPaymentRow> payments;
}

