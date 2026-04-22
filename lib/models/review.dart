/// A single TMDB review. TMDB's `/reviews` endpoint returns a richer object
/// (author_details, url, etc.) but the UI only needs these few fields.
class Review {
  final String id;
  final String author;
  final String content;
  final double? rating;
  final DateTime? createdAt;

  const Review({
    required this.id,
    required this.author,
    required this.content,
    this.rating,
    this.createdAt,
  });

  factory Review.fromMap(Map<String, dynamic> m) {
    final details = m['author_details'] as Map<String, dynamic>?;
    double? rating;
    final r = details?['rating'];
    if (r is num) rating = r.toDouble();

    DateTime? created;
    final c = m['created_at'] as String?;
    if (c != null && c.isNotEmpty) created = DateTime.tryParse(c);

    return Review(
      id: (m['id'] as String?) ?? '',
      author: (m['author'] as String?)?.trim().isNotEmpty == true
          ? (m['author'] as String).trim()
          : (details?['username'] as String?) ?? 'Anonymous',
      content: (m['content'] as String?) ?? '',
      rating: rating,
      createdAt: created,
    );
  }
}
