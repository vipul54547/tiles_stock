/// Stockist membership tiers, highest first. Used to order how stockists are
/// listed to buyers (tier → priority → auto stock-ranking).
const List<String> kStockistTiers = ['Platinum', 'Gold', 'Silver'];

/// Sort rank for a tier — higher is shown first. Platinum 3, Gold 2, Silver 1,
/// none/unknown 0.
int stockistTierRank(String? type) {
  switch ((type ?? '').toLowerCase().trim()) {
    case 'platinum':
      return 3;
    case 'gold':
      return 2;
    case 'silver':
      return 1;
    default:
      return 0;
  }
}
