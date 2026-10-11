import type { PlanCode } from "./types";
export type PlanPrices = Record<PlanCode, number>;
export const launchPrices: PlanPrices = { starter: 1500000, business: 3500000, group: 7500000 };
export function naira(kobo: number) {
  return new Intl.NumberFormat("en-NG", { style: "currency", currency: "NGN", maximumFractionDigits: 2, minimumFractionDigits: 0 }).format(kobo / 100);
}
export function parseAmountKobo(value: string): number | null {
  if (!/^\d+(?:\.\d{1,2})?$/.test(value)) return null;
  const [whole, fraction = ""] = value.split(".");
  const amount = Number(whole) * 100 + Number(fraction.padEnd(2, "0"));
  return Number.isSafeInteger(amount) ? amount : null;
}
