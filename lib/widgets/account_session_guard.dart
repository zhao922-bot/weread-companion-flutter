import 'package:flutter/material.dart';
import '../services/database.dart';

/// Pushed routes outlive the main screen's account reset. Bind their contents
/// to the original session, including when reopening the same account.
class AccountSessionGuard extends StatelessWidget {
  const AccountSessionGuard(
      {super.key, required this.database, required this.child});

  final DatabaseService database;
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: database.sessionActive,
        child: child,
        builder: (context, _, child) => database.isActive
            ? child!
            : Scaffold(
                appBar: AppBar(title: const Text('会话已结束')),
                body: const Center(child: Text('账号会话已结束，请返回后重试')),
              ),
      );
}
