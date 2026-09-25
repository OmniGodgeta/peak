/// The reaction kinds `reaction_kind` supports in the database
/// (supabase/migrations/20260908205707_posts_feed.sql). Kept as a plain
/// string on the wire — `toggle_reaction`'s `p_kind` param takes the enum's
/// literal name.
enum ReactionKind {
  like,
  celebrate,
  support,
  insightful,
  curious;

  String get label => switch (this) {
    ReactionKind.like => 'Like',
    ReactionKind.celebrate => 'Celebrate',
    ReactionKind.support => 'Support',
    ReactionKind.insightful => 'Insightful',
    ReactionKind.curious => 'Curious',
  };
}
