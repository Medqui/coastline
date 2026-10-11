export type PlanCode = "starter" | "business" | "group";
export type Feature = "advanced_reports" | "supplier_accounts" | "inventory" | "staff_shifts" | "multi_property";
export type SubscriptionAccess = {
  plan_code: PlanCode | null; plan_name?: string; status?: "trialing" | "active" | "past_due" | "expired" | "cancelled";
  access: "full" | "grace" | "read_only"; features: Feature[]; staff_limit?: number | null; property_limit?: number | null;
  grandfathered?: boolean; trial_ends_at?: string | null; current_period_end?: string | null; monthly_fee_kobo?: number | null;
};
export const plans = [
  { code: "starter", name: "Starter", description: "Everything you need to run a hotel day to day.", capacity: "1 hotel · 5 staff accounts", features: ["Reservations and room availability", "Check-in, checkout and housekeeping", "Guest bills, deposits and receipts", "Dashboard, expenses and basic exports"] },
  { code: "business", name: "Business", description: "Deeper financial insight and better team coordination.", capacity: "1 hotel · 15 staff accounts", features: ["Everything in Starter", "Detailed statements and bank reconciliation", "Supplier invoices and payments", "Inventory and low-stock tracking", "Staff shifts and handovers"] },
  { code: "group", name: "Group", description: "One workspace for a business with multiple hotels.", capacity: "Multiple hotels · unlimited staff in this release", features: ["Everything in Business", "Multiple properties", "Property comparisons", "Staff access across assigned properties"] },
] as const;
export const featureLabels: Record<Feature, string> = { advanced_reports: "Detailed financial reports", supplier_accounts: "Supplier accounts", inventory: "Inventory", staff_shifts: "Shift workspace", multi_property: "Multiple properties" };
export function hasFeature(access: SubscriptionAccess | undefined, feature: Feature) {
  // Older databases remain usable until migration 019 is installed.
  return access === undefined || access.features.includes(feature);
}
export type PlatformHotel = {
  id: string; name: string; created_at: string; owner_email: string | null; onboarded: boolean; is_test: boolean;
  properties: number; rooms: number; staff: number; last_activity_at: string | null; monthly_fee_kobo: number | null;
  subscription: SubscriptionAccess;
};
export type PlatformOverview = { hotels: PlatformHotel[]; as_of: string };
export type SubscriptionReceipt = {
  id: string; organization_id: string; organization_name: string; plan_code: PlanCode;
  entry_type: "payment" | "refund"; original_payment_id: string | null; amount_kobo: number;
  received_on: string; method: string; reference: string; note: string; is_test: boolean;
  refunded_kobo: number; created_at: string;
};
export type PlatformRevenueReport = {
  as_of: string; include_tests: boolean; prices: Record<PlanCode, number>;
  mrr_kobo: number; paying_customers: number; at_risk_mrr_kobo: number;
  received_this_month_kobo: number; refunded_this_month_kobo: number;
  received_all_time_kobo: number; refunded_all_time_kobo: number;
  months: { month: string; received_kobo: number; refunded_kobo: number }[];
  tiers: { code: PlanCode; customers: number; mrr_kobo: number; net_this_month_kobo: number }[];
  receipts: SubscriptionReceipt[];
};
export type PlatformRevenue = { standard: PlatformRevenueReport; includingTests: PlatformRevenueReport };
