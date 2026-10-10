import 'note_item.dart';

class SummaryReference {
  final String label;
  final String noteId;
  final String bookId;
  final String bookTitle;
  final String chapterTitle;
  final NoteSource source;
  final String content;

  SummaryReference({required this.label, required this.noteId,
    required this.bookId, required this.bookTitle, required this.chapterTitle,
    required this.source, required this.content});

  factory SummaryReference.fromNote(NoteItem note, int index) => SummaryReference(
    label: 'R${index + 1}', noteId: note.id, bookId: note.bookId,
    bookTitle: note.bookTitle, chapterTitle: note.chapterTitle,
    source: note.source, content: note.content);

  factory SummaryReference.fromJson(Map<String, dynamic> json) => SummaryReference(
    label: json['label'], noteId: json['note_id'], bookId: json['book_id'],
    bookTitle: json['book_title'], chapterTitle: json['chapter_title'],
    source: NoteSource.values.byName(json['source']), content: json['content']);

  Map<String, dynamic> toJson() => {
    'label': label, 'note_id': noteId, 'book_id': bookId,
    'book_title': bookTitle, 'chapter_title': chapterTitle,
    'source': source.name, 'content': content,
  };
}

class AISummary {
  final int createdAt;
  final String title;
  final String text;
  final List<SummaryReference> references;

  AISummary({required this.createdAt, required this.title, required this.text,
    required List<SummaryReference> references})
      : references = List.unmodifiable(references);

  String get coverage => '基于 ${references.map((r) => r.bookId).toSet().length} 本书 ${references.length} 条笔记（划线/笔记，最新最多 30 条）';

  factory AISummary.fromJson(Map<String, dynamic> json) => AISummary(
    createdAt: json['created_at'], title: json['title'], text: json['text'],
    references: (json['references'] as List).map((r) =>
      SummaryReference.fromJson(Map<String, dynamic>.from(r))).toList());

  Map<String, dynamic> toJson() => {
    'created_at': createdAt, 'title': title, 'text': text,
    'references': references.map((r) => r.toJson()).toList(),
  };
}
