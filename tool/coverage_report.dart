import 'dart:convert';
import 'dart:io';

/// Reproducible inventory of every missing line/branch, without exclusions.
/// Run after `flutter test --branch-coverage
/// --coverage-path=build/coverage/lcov.info`.
/// `--require-full` returns a failing exit code until both counters reach 100%.
void main(List<String> arguments) {
  final input = File('build/coverage/lcov.info');
  final files = <Map<String, Object?>>[];
  final represented = <String>{};
  final auditFile = File('tool/coverage_audit.json');
  final audit = auditFile.existsSync()
      ? jsonDecode(auditFile.readAsStringSync()) as Map<String, dynamic>
      : <String, dynamic>{};
  final findings = <String, Map<String, dynamic>>{
    for (final entry in (audit['findings'] as List? ?? []).cast<Map>())
      '${entry['file']}:${entry['line']}': Map<String, dynamic>.from(entry),
  };
  var unreviewed = 0;
  Map<String, Object?> review(String path, int line, String code) {
    final entry = findings['${path.replaceAll('\\', '/')}:$line'];
    if (entry == null || entry['code'] != code) {
      unreviewed++;
      return {'review': 'unreviewed'};
    }
    return {'review': entry['category'], 'reason': entry['reason']};
  }

  var totalLines = 0;
  var hitLines = 0;
  var totalBranches = 0;
  var hitBranches = 0;
  for (final record in input.readAsStringSync().split('end_of_record')) {
    final source = RegExp(r'^SF:(.+)', multiLine: true).firstMatch(record);
    if (source == null) continue;
    final path = source.group(1)!.trim();
    represented.add(File(path).absolute.uri.normalizePath().toString());
    final contents = File(path).readAsLinesSync();
    String code(int line) => line > 0 && line <= contents.length
        ? contents[line - 1].trim()
        : '<source line unavailable>';
    final lines =
        RegExp(r'^DA:(\d+),(\d+)', multiLine: true).allMatches(record);
    final branches =
        RegExp(r'^BRDA:(\d+),(\d+),(\d+),([\d-]+)', multiLine: true)
            .allMatches(record);
    final missingLines = <Map<String, Object>>[];
    final missingBranches = <Map<String, Object>>[];
    for (final match in lines) {
      final line = int.parse(match.group(1)!);
      if (int.parse(match.group(2)!) == 0) {
        missingLines.add({'line': line, 'code': code(line)});
      }
    }
    for (final match in branches) {
      final line = int.parse(match.group(1)!);
      if (match.group(4) == '-' || int.parse(match.group(4)!) == 0) {
        missingBranches.add({
          'line': line,
          'block': match.group(2)!,
          'branch': match.group(3)!,
          'code': code(line),
        });
      }
    }
    totalLines += lines.length;
    hitLines += lines.length - missingLines.length;
    totalBranches += branches.length;
    hitBranches += branches.length - missingBranches.length;
    files.add({
      'file': path,
      'lines': lines.length,
      'coveredLines': lines.length - missingLines.length,
      'branches': branches.length,
      'coveredBranches': branches.length - missingBranches.length,
      'missingLines': [
        for (final gap in missingLines)
          {...gap, ...review(path, gap['line'] as int, gap['code'] as String)}
      ],
      'missingBranches': [
        for (final gap in missingBranches)
          {...gap, ...review(path, gap['line'] as int, gap['code'] as String)}
      ],
    });
  }
  if (totalLines == 0 || totalBranches == 0) {
    throw const FormatException(
        'LCOV must contain both line and branch records');
  }
  final unrepresented = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) =>
          file.path.endsWith('.dart') &&
          !represented.contains(file.absolute.uri.normalizePath().toString()))
      .map((file) => file.path)
      .toList()
    ..sort();
  // Only simple numeric constant declarations and comments have no executable
  // code. Anything else absent from LCOV must fail the gate, never count as 100%.
  final unknownFiles = unrepresented
      .where((path) => !File(path).readAsLinesSync().every((line) {
            final text = line.trim();
            return text.isEmpty ||
                text.startsWith('//') ||
                RegExp(r'^const (?:int|double) \w+ = -?\d+(?:\.\d+)?;$')
                    .hasMatch(text);
          }))
      .toList();
  files.sort((a, b) => (a['file'] as String).compareTo(b['file'] as String));
  final output = File('build/coverage/report.json');
  output.writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
    'schemaVersion': 1,
    'input': input.path,
    'summary': {
      'coveredLines': hitLines,
      'lines': totalLines,
      'coveredBranches': hitBranches,
      'branches': totalBranches,
    },
    // Constants-only files can legitimately have no executable coverage record.
    // List them explicitly instead of silently treating absent files as covered.
    'filesWithoutCoverageRecords': unrepresented,
    'unverifiedFilesWithoutRecords': unknownFiles,
    'unreviewedGaps': unreviewed,
    'note':
        'Reviewed gaps remain uncovered and are included in every denominator.',
    'files': files,
  }));
  final readable = StringBuffer()
    ..writeln(
        '行覆盖: $hitLines/$totalLines (${(100 * hitLines / totalLines).toStringAsFixed(2)}%)')
    ..writeln(
        '分支覆盖: $hitBranches/$totalBranches (${(100 * hitBranches / totalBranches).toStringAsFixed(2)}%)')
    ..writeln('所有缺口保留在覆盖率分母中；审查依据不等于测试通过。')
    ..writeln('LCOV 无记录文件: ${unrepresented.join(', ')}')
    ..writeln('未审查缺口: $unreviewed\n');
  for (final file in files) {
    readable.writeln(
        '${file['file']}  行 ${file['coveredLines']}/${file['lines']}  分支 ${file['coveredBranches']}/${file['branches']}');
    for (final kind in ['missingLines', 'missingBranches']) {
      for (final gap in file[kind] as List) {
        readable.writeln(
            '  ${kind == 'missingLines' ? '行' : '分支'} ${gap['line']}: ${gap['code']}');
        readable.writeln('    ${gap['review']}: ${gap['reason'] ?? '待审查'}');
      }
    }
  }
  File('build/coverage/report.txt').writeAsStringSync(readable.toString());
  stdout.writeln('Lines: $hitLines/$totalLines '
      '(${(100 * hitLines / totalLines).toStringAsFixed(2)}%)');
  stdout.writeln('Branches: $hitBranches/$totalBranches '
      '(${(100 * hitBranches / totalBranches).toStringAsFixed(2)}%)');
  stdout.writeln('Full inventory: ${output.path}');
  if (unrepresented.isNotEmpty) {
    stdout.writeln('Files without records: ${unrepresented.join(', ')}');
  }
  if (arguments.contains('--require-full') &&
      (hitLines != totalLines ||
          hitBranches != totalBranches ||
          unknownFiles.isNotEmpty)) {
    exitCode = 1;
  }
  if (arguments.contains('--check') &&
      (audit.isEmpty ||
          unreviewed > 0 ||
          unknownFiles.isNotEmpty ||
          100 * hitLines / totalLines <
              (audit['minimumLinePercent'] as num? ?? 100) ||
          100 * hitBranches / totalBranches <
              (audit['minimumBranchPercent'] as num? ?? 100))) {
    exitCode = 1;
  }
}
