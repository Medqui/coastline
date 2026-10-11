import { plans, type SubscriptionAccess } from "./types";

export function availableUpgradePlans(subscription: SubscriptionAccess) {
  const currentIndex = plans.findIndex(plan => plan.code === subscription.plan_code);
  const canActivateCurrent = subscription.grandfathered || subscription.status === "trialing";
  return plans.filter((_, index) => index > currentIndex || (index === currentIndex && canActivateCurrent));
}

export function upgradeEndDateError(value: string, now = Date.now()) {
  if (!value) return null;
  const periodEnd = Date.parse(`${value}T23:59:59+01:00`);
  return Number.isNaN(periodEnd) || periodEnd <= now ? "Choose today or a future billing end date so the upgraded plan is active." : null;
}

export function billingDateInput(value: string | null | undefined) {
  if (!value) return "";
  const parts = new Intl.DateTimeFormat("en-GB", { year: "numeric", month: "2-digit", day: "2-digit", timeZone: "Africa/Lagos" }).formatToParts(new Date(value));
  const part = (type: string) => parts.find(item => item.type === type)?.value;
  return `${part("year")}-${part("month")}-${part("day")}`;
}
