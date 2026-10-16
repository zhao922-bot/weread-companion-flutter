import 'dart:async';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../sync_database_regression_test.dart'
    show FaultFactory, LegacyDatabase;

/// Records result sizes, including statements inside onOpen and transactions.
class DatabaseProbe {
  final reads = <({String sql, int rows})>[];
  final deletes = <({String sql, int arguments})>[];
  FutureOr<void> Function(String sql)? beforeExecute;
  FutureOr<void> Function(String sql)? afterExecute;
  FutureOr<void> Function(String sql)? afterRead;
  FutureOr<void> Function(String table)? afterUpdate;
  FutureOr<void> Function()? beforeCommit;
  FutureOr<void> Function()? afterCommit;
  void Function()? onTransactionStart;

  Future<List<Map<String, Object?>>> observe(
      String sql, Future<List<Map<String, Object?>>> result) async {
    final rows = await result;
    reads.add((sql: sql, rows: rows.length));
    await afterRead?.call(sql);
    return rows;
  }
}

class ObservedFactory extends FaultFactory {
  final DatabaseProbe probe;
  ObservedFactory(super.delegate, this.probe);

  @override
  Future<Database> openDatabase(String path,
      {OpenDatabaseOptions? options}) async {
    final onOpen = options?.onOpen;
    if (onOpen != null) {
      options!.onOpen = (db) => onOpen(_ObservedDatabase(db, probe));
    }
    return _ObservedDatabase(
        await super.openDatabase(path, options: options), probe);
  }
}

class _ObservedDatabase extends LegacyDatabase {
  final DatabaseProbe probe;
  _ObservedDatabase(Database database, this.probe) : super(database, '3.40.0');

  @override
  Batch batch() => delegate.batch();

  @override
  Future<int> insert(String table, Map<String, Object?> values,
          {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) =>
      delegate.insert(table, values,
          nullColumnHack: nullColumnHack, conflictAlgorithm: conflictAlgorithm);

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    await probe.beforeExecute?.call(sql);
    await delegate.execute(sql, arguments);
    await probe.afterExecute?.call(sql);
  }

  @override
  Future<List<Map<String, Object?>>> query(String table,
          {bool? distinct,
          List<String>? columns,
          String? where,
          List<Object?>? whereArgs,
          String? groupBy,
          String? having,
          String? orderBy,
          int? limit,
          int? offset}) =>
      probe.observe(
          table,
          delegate.query(table,
              distinct: distinct,
              columns: columns,
              where: where,
              whereArgs: whereArgs,
              groupBy: groupBy,
              having: having,
              orderBy: orderBy,
              limit: limit,
              offset: offset));

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql,
          [List<Object?>? arguments]) =>
      probe.observe(sql, delegate.rawQuery(sql, arguments));

  @override
  Future<int> update(String table, Map<String, Object?> values,
      {String? where,
      List<Object?>? whereArgs,
      ConflictAlgorithm? conflictAlgorithm}) async {
    final changed = await delegate.update(table, values,
        where: where,
        whereArgs: whereArgs,
        conflictAlgorithm: conflictAlgorithm);
    await probe.afterUpdate?.call(table);
    return changed;
  }

  @override
  Future<T> transaction<T>(Future<T> Function(Transaction txn) action,
      {bool? exclusive}) async {
    probe.onTransactionStart?.call();
    final result = await delegate.transaction((txn) async {
      final result = await action(_ObservedTransaction(txn, probe));
      await probe.beforeCommit?.call();
      return result;
    }, exclusive: exclusive);
    await probe.afterCommit?.call();
    return result;
  }
}

class _ObservedTransaction implements Transaction {
  final Transaction delegate;
  final DatabaseProbe probe;
  _ObservedTransaction(this.delegate, this.probe);

  @override
  Batch batch() => delegate.batch();

  @override
  Future<int> delete(String table, {String? where, List<Object?>? whereArgs}) {
    probe.deletes.add((sql: table, arguments: whereArgs?.length ?? 0));
    return delegate.delete(table, where: where, whereArgs: whereArgs);
  }

  @override
  Future<int> rawDelete(String sql, [List<Object?>? arguments]) {
    probe.deletes.add((sql: sql, arguments: arguments?.length ?? 0));
    return delegate.rawDelete(sql, arguments);
  }

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) async {
    await probe.beforeExecute?.call(sql);
    await delegate.execute(sql, arguments);
    await probe.afterExecute?.call(sql);
  }

  @override
  Future<List<Map<String, Object?>>> query(String table,
          {bool? distinct,
          List<String>? columns,
          String? where,
          List<Object?>? whereArgs,
          String? groupBy,
          String? having,
          String? orderBy,
          int? limit,
          int? offset}) =>
      probe.observe(
          table,
          delegate.query(table,
              distinct: distinct,
              columns: columns,
              where: where,
              whereArgs: whereArgs,
              groupBy: groupBy,
              having: having,
              orderBy: orderBy,
              limit: limit,
              offset: offset));

  @override
  Future<List<Map<String, Object?>>> rawQuery(String sql,
          [List<Object?>? arguments]) =>
      probe.observe(sql, delegate.rawQuery(sql, arguments));

  @override
  Future<int> insert(String table, Map<String, Object?> values,
          {String? nullColumnHack, ConflictAlgorithm? conflictAlgorithm}) =>
      delegate.insert(table, values,
          nullColumnHack: nullColumnHack, conflictAlgorithm: conflictAlgorithm);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
