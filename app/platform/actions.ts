"use server";
import { revalidatePath } from "next/cache";
import { createClient } from "@/lib/supabase/server";
import { plans, type PlatformOverview } from "@/lib/saas/types";
import { parseAmountKobo } from "@/lib/saas/pricing";
import { availableUpgradePlans, upgradeEndDateError } from "@/lib/saas/upgrades";
export type SubscriptionActionState = { error?: string; success?: boolean; planName?: string };
export async function updateSubscription(_previous: SubscriptionActionState, form: FormData): Promise<SubscriptionActionState> {
  const db = await createClient();
  const { data: { user } } = await db.auth.getUser();
  if (!user) return { error: "Sign in to manage subscriptions." };
  const { data: admin, error: adminError } = await db.rpc("is_platform_admin");
  if (adminError || !admin) return { error: "Platform administrator access is required." };
  const text = (key: string) => String(form.get(key) ?? "").trim();
  const isUpgrade = text("intent") === "upgrade";
  const plan = plans.find(item => item.code === text("plan"));
  if (!plan) return { error: "Choose a valid subscription plan." };
  const reason = text("reason");
  if (reason.length < 5 || reason.length > 500) return { error: "Give a reason between 5 and 500 characters for this subscription change." };
  let isTest = form.get("is_test") === "on";
  if (isUpgrade) {
    const { data, error } = await db.rpc("get_platform_overview");
    if (error || !data) return { error: "Could not check the current subscription. Refresh and try again." };
    const hotel = (data as PlatformOverview).hotels.find(item => item.id === text("organization_id"));
    if (!hotel) return { error: "Hotel subscription not found." };
    if (!availableUpgradePlans(hotel.subscription).some(item => item.code === plan.code)) return { error: "This plan is no longer an available upgrade. Refresh the hotel’s subscription and try again." };
    isTest = hotel.is_test;
  }
  const fee = text("monthly_fee");
  if (fee && !/^\d+(?:\.\d{1,2})?$/.test(fee)) return { error: "Enter a valid monthly subscription amount." };
  const [whole, fraction = ""] = fee.split(".");
  const feeKobo = fee ? Number(whole) * 100 + Number(fraction.padEnd(2, "0")) : null;
  if (feeKobo !== null && !Number.isSafeInteger(feeKobo)) return { error: "Subscription amount is too large." };
  const date = text("period_end");
  if (date && (!/^\d{4}-\d{2}-\d{2}$/.test(date) || Number.isNaN(Date.parse(date)) || new Date(date).toISOString().slice(0,10) !== date)) return { error: "Choose a valid end date." };
  if (isUpgrade) {
    const endDateError = upgradeEndDateError(date);
    if (endDateError) return { error: endDateError };
  }
  const { error } = await db.rpc("set_platform_subscription", { p_organization_id: text("organization_id"), p_plan_code: plan.code, p_status: isUpgrade ? "active" : text("status"),
    p_period_end: date ? `${date}T23:59:59+01:00` : null, p_monthly_fee_kobo: feeKobo, p_is_test: isTest, p_reason: reason });
  if (error) return { error: error.message };
  revalidatePath("/platform"); revalidatePath("/subscription"); revalidatePath("/");
  return { success: true, planName: plan.name };
}


export type ReceiptActionState = { error?: string; success?: boolean; receiptId?: string };
export async function recordSubscriptionReceipt(_previous: ReceiptActionState, form: FormData): Promise<ReceiptActionState> {
  const db = await createClient();
  const { data: { user } } = await db.auth.getUser();
  if (!user) return { error: "Sign in to record subscription payments." };
  const { data: admin, error: adminError } = await db.rpc("is_platform_admin");
  if (adminError || !admin) return { error: "Platform administrator access is required." };
  const text = (name: string) => String(form.get(name) ?? "").trim();
  const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
  if (!uuid.test(text("request_id")) || !uuid.test(text("organization_id"))) return { error: "Choose a customer and reopen the payment form." };
  const amount = parseAmountKobo(text("amount"));
  if (amount === null || amount <= 0) return { error: "Enter a positive amount with at most two decimal places." };
  const receivedOn = text("received_on");
  if (!/^\d{4}-\d{2}-\d{2}$/.test(receivedOn) || Number.isNaN(Date.parse(receivedOn)) || new Date(receivedOn).toISOString().slice(0,10) !== receivedOn) return { error: "Choose a valid payment date." };
  const entryType = text("entry_type");
  if (!["payment", "refund"].includes(entryType)) return { error: "Choose payment or refund." };
  if (entryType === "refund" && !uuid.test(text("original_payment_id"))) return { error: "Choose the original payment to refund." };
  const reference = text("reference"); const note = text("note");
  if (reference.length < 2 || reference.length > 150) return { error: "Enter a unique reference between 2 and 150 characters." };
  if (note.length < 5 || note.length > 500) return { error: "Add a note between 5 and 500 characters." };
  const { data, error } = await db.rpc("record_subscription_receipt", {
    p_request_id: text("request_id"), p_organization_id: text("organization_id"), p_plan_code: text("plan"),
    p_entry_type: entryType, p_original_payment_id: entryType === "refund" ? text("original_payment_id") : null,
    p_amount_kobo: amount, p_received_on: receivedOn, p_method: text("method"), p_reference: reference, p_note: note,
  });
  if (error) return { error: error.message };
  revalidatePath("/platform");
  return { success: true, receiptId: data as string };
}
