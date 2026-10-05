"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";

export type ActionState = { error?: string; success?: boolean; result?: string; notice?: string };

export async function saveSupplierAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { error: "Sign in to manage suppliers." };
  const { error } = await supabase.rpc("save_supplier", { p_property_id: text(formData,"property_id"),
    p_supplier_id: text(formData,"supplier_id") || null, p_name: text(formData,"name"), p_phone: text(formData,"phone") || null,
    p_email: text(formData,"email") || null, p_address: text(formData,"address") || null, p_active: formData.get("active") === "on" });
  if (error) return { error: friendlyError(error.message) };
  revalidatePath("/"); return { success: true };
}

export async function postSupplierBillAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const amount = nairaToKobo(text(formData,"amount"));
  const receipt = formData.get("receipt_file");
  if (!amount) return { error: "Enter a positive bill amount." };
  if (receipt instanceof File && receipt.size > 10*1024*1024) return { error: "Receipt files must be 10 MB or smaller." };
  if (receipt instanceof File && receipt.size > 0 && !["image/jpeg","image/png","application/pdf"].includes(receipt.type)) return { error: "Use a JPG, PNG or PDF receipt." };
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { error: "Sign in to record a supplier bill." };
  const propertyId = text(formData,"property_id");
  const { data: billId,error } = await supabase.rpc("post_supplier_bill", { p_property_id: propertyId, p_supplier_id: text(formData,"supplier_id"),
    p_bill_number: text(formData,"bill_number"), p_invoice_date: text(formData,"invoice_date"), p_posting_date: text(formData,"posting_date"),
    p_due_date: text(formData,"due_date"), p_description: text(formData,"description"), p_account_code: text(formData,"account_code"),
    p_department_id: text(formData,"department_id"), p_amount_kobo: amount, p_idempotency_key: text(formData,"idempotency_key") });
  if (error) return { error: friendlyError(error.message) };
  let notice = "";
  if (receipt instanceof File && receipt.size > 0) {
    const { data: property } = await supabase.from("properties").select("organization_id").eq("id",propertyId).maybeSingle();
    const extension = receipt.type === "application/pdf" ? "pdf" : receipt.type === "image/png" ? "png" : "jpg";
    const path = `${property?.organization_id}/${propertyId}/${billId}/${crypto.randomUUID()}.${extension}`;
    const { error: uploadError } = await supabase.storage.from("expense-receipts").upload(path,receipt,{contentType:receipt.type,upsert:false});
    if (uploadError) notice = "Bill recorded, but its receipt could not be saved.";
    else {
      const { error: attachError } = await supabase.rpc("attach_supplier_bill_receipt",{p_bill_id:billId,p_storage_path:path});
      if (attachError) notice = "Bill recorded, but its receipt could not be linked. Contact the hotel administrator.";
    }
  }
  revalidatePath("/"); return { success: true, result: String(billId), notice };
}

export async function attachSupplierBillReceiptAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const receipt = formData.get("receipt_file");
  if (!(receipt instanceof File) || receipt.size === 0) return { error: "Choose an invoice receipt." };
  if (receipt.size > 10 * 1024 * 1024) return { error: "Receipt files must be 10 MB or smaller." };
  if (!["image/jpeg", "image/png", "application/pdf"].includes(receipt.type)) return { error: "Use a JPG, PNG or PDF receipt." };
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { error: "Sign in to attach an invoice receipt." };
  const billId = text(formData, "bill_id");
  const { data: bill, error: readError } = await supabase.from("supplier_bills").select("organization_id,property_id").eq("id", billId).maybeSingle();
  if (readError || !bill) return { error: "This bill is unavailable. Refresh supplier accounts." };
  const extension = receipt.type === "application/pdf" ? "pdf" : receipt.type === "image/png" ? "png" : "jpg";
  const path = `${bill.organization_id}/${bill.property_id}/${billId}/${crypto.randomUUID()}.${extension}`;
  const { error: uploadError } = await supabase.storage.from("expense-receipts").upload(path, receipt, { contentType: receipt.type, upsert: false });
  if (uploadError) return { error: "The receipt could not be saved. Try again." };
  const { error } = await supabase.rpc("attach_supplier_bill_receipt", { p_bill_id: billId, p_storage_path: path });
  if (error) return { error: "The receipt could not be linked. Contact the hotel administrator." };
  revalidatePath("/"); return { success: true };
}

export async function paySupplierBillAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const amount = nairaToKobo(text(formData,"amount"));
  if (!amount) return { error: "Enter a positive payment amount." };
  return runFinanceAction("pay_supplier_bill", { p_bill_id: text(formData,"bill_id"), p_payment_method_id: text(formData,"payment_method_id"),
    p_payment_date: text(formData,"payment_date"), p_amount_kobo: amount, p_reference: text(formData,"reference") || null,
    p_idempotency_key: text(formData,"idempotency_key") });
}
export async function reverseSupplierPaymentAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  return runFinanceAction("reverse_supplier_payment", { p_payment_id: text(formData,"payment_id"), p_date: text(formData,"date"), p_reason: text(formData,"reason") });
}
export async function voidSupplierBillAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  return runFinanceAction("void_supplier_bill", { p_bill_id: text(formData,"bill_id"), p_date: text(formData,"date"), p_reason: text(formData,"reason") });
}

export async function classifyCashFlowAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  return runFinanceAction("classify_cash_flow", { p_journal_id: text(formData,"journal_id"), p_activity: text(formData,"activity"),
    p_reason: text(formData,"reason"), p_idempotency_key: text(formData,"idempotency_key") });
}

export async function setRoomBaseRateAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const rate = nairaToKobo(text(formData, "rate"));
  if (rate === null) return { error: "Enter a valid room rate." };
  return runFinanceAction("set_room_base_rate", { p_room_type_id: text(formData, "room_type_id"), p_rate_kobo: rate, p_reason: text(formData, "reason") });
}

export async function scheduleRoomRateAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const rate = nairaToKobo(text(formData, "rate"));
  const lastNight = text(formData, "last_night");
  if (rate === null || !/^\d{4}-\d{2}-\d{2}$/.test(lastNight)) return { error: "Enter a valid rate and date range." };
  const end = new Date(`${lastNight}T00:00:00Z`);
  if (Number.isNaN(end.getTime()) || end.toISOString().slice(0, 10) !== lastNight) return { error: "Enter a valid last night." };
  end.setUTCDate(end.getUTCDate() + 1);
  return runFinanceAction("schedule_room_rate", { p_room_type_id: text(formData, "room_type_id"), p_name: text(formData, "name"),
    p_starts_on: text(formData, "first_night"), p_ends_before: end.toISOString().slice(0, 10), p_rate_kobo: rate });
}

export async function retireRoomRateAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  return runFinanceAction("retire_room_rate", { p_period_id: text(formData, "period_id"), p_reason: text(formData, "reason") });
}

export async function reportMaintenanceAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { error: "Sign in to report maintenance." };
  const title = text(formData, "title");
  if (title.length < 3 || title.length > 120) return { error: "Enter an issue title between 3 and 120 characters." };
  const { error } = await supabase.rpc("report_maintenance", {
    p_room_id: text(formData, "room_id"), p_title: title, p_description: text(formData, "description") || null,
    p_priority: text(formData, "priority"), p_blocks_inventory: formData.get("blocks_inventory") === "on",
    p_idempotency_key: text(formData, "idempotency_key"),
  });
  if (error) return { error: friendlyError(error.message) };
  revalidatePath("/");
  return { success: true };
}

export async function transitionMaintenanceAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  return runFinanceAction("transition_maintenance", { p_work_order_id: text(formData, "work_order_id"),
    p_status: text(formData, "status"), p_notes: text(formData, "notes") || null });
}

function text(formData: FormData, key: string) {
  const value = formData.get(key);
  return typeof value === "string" ? value.trim() : "";
}
function nairaToKobo(value: string) {
  if (!/^\d+(?:\.\d{1,2})?$/.test(value)) return null;
  const [whole, fraction = ""] = value.split(".");
  const amount = Number(whole) * 100 + Number(fraction.padEnd(2, "0"));
  return Number.isSafeInteger(amount) ? amount : null;
}

export async function setupHotelAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { error: "Sign in before setting up your hotel." };

  const organizationName = text(formData, "organization_name");
  const propertyName = text(formData, "property_name");
  const address = text(formData, "address");
  const roomCount = Number(text(formData, "room_count"));
  const standardRateKobo = nairaToKobo(text(formData, "standard_rate"));
  if (organizationName.length < 2 || propertyName.length < 2) return { error: "Enter your organization and property names." };
  if (!Number.isInteger(roomCount) || roomCount < 1 || roomCount > 300) return { error: "Room count must be between 1 and 300." };
  if (standardRateKobo === null) return { error: "Enter a valid nightly room rate." };

  const { error } = await supabase.rpc("setup_hotel", {
    p_organization_name: organizationName,
    p_property_name: propertyName,
    p_address: address,
    p_room_count: roomCount,
    p_standard_rate_kobo: standardRateKobo,
  });
  if (error) return { error: friendlyError(error.message) };
  revalidatePath("/");
  redirect("/");
}

export async function createReservationAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { error: "Sign in before creating a reservation." };

  const organizationId = text(formData, "organization_id");
  const propertyId = text(formData, "property_id");
  const roomId = text(formData, "room_id");
  const guestName = text(formData, "guest_name");
  const guestPhone = text(formData, "guest_phone");
  const guestEmail = text(formData, "guest_email");
  const arrivalDate = text(formData, "arrival_date");
  const departureDate = text(formData, "departure_date");
  const adults = Number(text(formData, "adults"));
  const pricingMode = text(formData, "pricing_mode");
  const nightlyRateKobo = pricingMode === "standard" ? null : nairaToKobo(text(formData, "nightly_rate"));
  let expectedQuote: { service_date: string; standard_rate_kobo: number }[];
  try {
    expectedQuote = JSON.parse(text(formData, "expected_quote"));
    if (!Array.isArray(expectedQuote) || !expectedQuote.length || expectedQuote.length > 366 || expectedQuote.some(night =>
      !night || !/^\d{4}-\d{2}-\d{2}$/.test(night.service_date) || !Number.isSafeInteger(night.standard_rate_kobo) || night.standard_rate_kobo < 0)) {
      return { error: "Load and review the nightly quote before confirming." };
    }
  } catch { return { error: "Load and review the nightly quote before confirming." }; }
  const notes = text(formData, "notes");

  if (!organizationId || !propertyId || !roomId) return { error: "Choose an available room." };
  if (guestName.length < 2) return { error: "Enter the guest’s full name." };
  if (!arrivalDate || !departureDate || departureDate <= arrivalDate) return { error: "Departure must be after arrival." };
  if (!Number.isInteger(adults) || adults < 1 || adults > 12) return { error: "Enter between 1 and 12 adults." };
  if (!["standard", "override"].includes(pricingMode) || (pricingMode === "override" && nightlyRateKobo === null)) return { error: "Enter a valid nightly rate." };

  const { error } = await supabase.rpc("create_priced_reservation", {
    p_organization_id: organizationId,
    p_property_id: propertyId,
    p_room_id: roomId,
    p_guest_name: guestName,
    p_guest_phone: guestPhone || null,
    p_guest_email: guestEmail || null,
    p_arrival_date: arrivalDate,
    p_departure_date: departureDate,
    p_adults: adults,
    p_nightly_rate_kobo: nightlyRateKobo,
    p_notes: notes || null,
    p_pricing_reason: text(formData, "pricing_reason") || null,
    p_expected_quote: expectedQuote,
  });
  if (error) return { error: friendlyError(error.message) };
  revalidatePath("/");
  return { success: true };
}

export async function checkInReservationAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const reservationId = text(formData, "reservation_id");
  if (!reservationId) return { error: "Reservation not found." };
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { error: "Sign in before checking in a guest." };
  const { error } = await supabase.rpc("check_in_reservation", { p_reservation_id: reservationId });
  if (error) return { error: friendlyError(error.message) };
  revalidatePath("/");
  return { success: true };
}

function friendlyError(message: string) {
  return message.replace(/^([A-Z0-9]{5}:\s*)/, "").replace(/^.*?ERROR:\s*/i, "");
}

export async function updateRoomHousekeepingAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const roomId = text(formData, "room_id");
  const status = text(formData, "status");
  if (!roomId || !["dirty", "clean", "inspected", "out_of_order"].includes(status)) return { error: "Choose a valid room status." };
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { error: "Sign in before updating housekeeping." };
  const { error } = await supabase.rpc("update_room_housekeeping_status", {
    p_room_id: roomId,
    p_status: status as "dirty" | "clean" | "inspected" | "out_of_order",
  });
  if (error) return { error: friendlyError(error.message) };
  revalidatePath("/");
  return { success: true };
}

async function runFinanceAction(functionName: string, args: Record<string, string | number | boolean | null>) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { error: "Sign in to continue." };
  const { error } = await supabase.rpc(functionName, args);
  if (error) return { error: friendlyError(error.message) };
  revalidatePath("/");
  return { success: true };
}

export async function postRoomNightsAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const reservationId = text(formData, "reservation_id");
  if (!reservationId) return { error: "Reservation not found." };
  return runFinanceAction("post_due_room_nights", { p_reservation_id: reservationId });
}

export async function postFolioChargeAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const folioId = text(formData, "folio_id");
  const description = text(formData, "description");
  const amount = nairaToKobo(text(formData, "amount"));
  const key = text(formData, "idempotency_key");
  if (!folioId || description.length < 2 || !amount || key.length < 8) return { error: "Enter a description and positive amount." };
  return runFinanceAction("post_department_folio_charge", {
    p_folio_id: folioId, p_description: description, p_amount_kobo: amount, p_idempotency_key: key,
    p_department_id: text(formData,"department_id"),
  });
}

export async function recordFolioPaymentAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const folioId = text(formData, "folio_id");
  const methodId = text(formData, "payment_method_id");
  const amount = nairaToKobo(text(formData, "amount"));
  const key = text(formData, "idempotency_key");
  if (!folioId || !methodId || !amount || key.length < 8) return { error: "Choose a method and enter a positive payment." };
  return runFinanceAction("record_folio_payment", {
    p_folio_id: folioId, p_payment_method_id: methodId, p_amount_kobo: amount,
    p_reference: text(formData, "reference") || null, p_idempotency_key: key,
  });
}

export async function postExpenseAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const propertyId = text(formData, "property_id");
  const methodId = text(formData, "payment_method_id");
  const categoryCode = text(formData, "expense_account_code") || "5000";
  const description = text(formData, "description");
  const amount = nairaToKobo(text(formData, "amount"));
  const key = text(formData, "idempotency_key");
  const receipt = formData.get("receipt_file");
  if (!propertyId || !methodId || description.length < 2 || !amount || key.length < 8) return { error: "Enter an expense, amount and payment method." };
  if (receipt instanceof File && receipt.size > 10 * 1024 * 1024) return { error: "Receipt files must be 10 MB or smaller." };
  if (receipt instanceof File && receipt.size > 0 && !["image/jpeg","image/png","application/pdf"].includes(receipt.type)) return { error: "Use a JPG, PNG, or PDF receipt." };
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { error: "Sign in to continue." };
  const { data: expenseId, error } = await supabase.rpc("post_department_expense", {
    p_property_id: propertyId, p_expense_account_code: categoryCode, p_description: description,
    p_vendor: text(formData, "vendor"), p_amount_kobo: amount,
    p_payment_method_id: methodId, p_idempotency_key: key,
    p_department_id: text(formData,"department_id"),
  });
  if (error) return { error: friendlyError(error.message) };
  let notice = "";
  if (receipt instanceof File && receipt.size > 0) {
    const { data: property } = await supabase.from("properties").select("organization_id").eq("id",propertyId).maybeSingle();
    const extension = receipt.type === "application/pdf" ? "pdf" : receipt.type === "image/png" ? "png" : "jpg";
    const path = `${property?.organization_id}/${propertyId}/${expenseId}/${crypto.randomUUID()}.${extension}`;
    const { error: uploadError } = await supabase.storage.from("expense-receipts").upload(path,receipt,{contentType:receipt.type,upsert:false});
    if (uploadError) notice = "Expense posted, but the receipt could not be saved. Check that the latest migration is installed.";
    else {
      const { error: attachError } = await supabase.rpc("attach_expense_receipt",{p_expense_id:expenseId,p_storage_path:path});
      if (attachError) {
        await supabase.storage.from("expense-receipts").remove([path]);
        notice = "Expense posted, but the receipt could not be linked. Check that the latest migration is installed.";
      }
    }
  }
  revalidatePath("/");
  return { success: true, result: String(expenseId), notice };
}

export async function checkOutReservationAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const reservationId = text(formData, "reservation_id");
  if (!reservationId) return { error: "Reservation not found." };
  return runFinanceAction("check_out_reservation", { p_reservation_id: reservationId });
}

export async function closeReservationAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const reservationId = text(formData, "reservation_id");
  const status = text(formData, "status");
  const reason = text(formData, "reason");
  if (!reservationId || !["cancelled","no_show"].includes(status) || reason.length < 3)
    return { error: "Choose a status and enter a reason." };
  return runFinanceAction("close_unchecked_reservation", {
    p_reservation_id: reservationId, p_status: status, p_reason: reason,
  });
}

export async function recordDepositAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const reservationId = text(formData, "reservation_id");
  const methodId = text(formData, "payment_method_id");
  const amount = nairaToKobo(text(formData, "amount"));
  const key = text(formData, "idempotency_key");
  if (!reservationId || !methodId || !amount || key.length < 8)
    return { error: "Choose a payment method and positive deposit." };
  return runFinanceAction("record_reservation_deposit", {
    p_reservation_id: reservationId, p_payment_method_id: methodId, p_amount_kobo: amount,
    p_reference: text(formData, "reference") || null, p_idempotency_key: key,
  });
}

export async function applyDepositAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const depositId = text(formData, "deposit_id");
  const amount = nairaToKobo(text(formData, "amount"));
  const key = text(formData, "idempotency_key");
  if (!depositId || !amount || key.length < 8) return { error: "Enter a positive deposit amount to apply." };
  return runFinanceAction("apply_guest_deposit", {
    p_deposit_id: depositId, p_amount_kobo: amount, p_idempotency_key: key,
  });
}

export async function refundPaymentAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const paymentId = text(formData, "payment_id");
  const amount = nairaToKobo(text(formData, "amount"));
  const reason = text(formData, "reason");
  const key = text(formData, "idempotency_key");
  if (!paymentId || !amount || reason.length < 5 || key.length < 8)
    return { error: "Enter a positive refund and a reason of at least 5 characters." };
  return runFinanceAction("request_guest_payment_refund", {
    p_payment_id: paymentId, p_amount_kobo: amount, p_reason: reason, p_idempotency_key: key,
  });
}

export async function openCashierShiftAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const openingFloat = nairaToKobo(text(formData,"opening_float"));
  if (openingFloat===null) return {error:"Enter a valid opening cash float."};
  return runFinanceAction("open_cashier_shift",{p_property_id:text(formData,"property_id"),p_opening_float_kobo:openingFloat,p_idempotency_key:text(formData,"idempotency_key")});
}

export async function closeCashierShiftAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const countedCash = nairaToKobo(text(formData,"counted_cash"));
  if (countedCash===null) return {error:"Enter the counted cash in the drawer."};
  return runFinanceAction("request_close_cashier_shift",{p_shift_id:text(formData,"shift_id"),p_counted_cash_kobo:countedCash,p_reason:text(formData,"reason")||null});
}

export async function reviewCashierShiftAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  return runFinanceAction("review_cashier_shift_close",{p_shift_id:text(formData,"shift_id"),p_approve:text(formData,"decision")==="approve",p_note:text(formData,"note")||null});
}

export async function reviewPaymentRefundAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  return runFinanceAction("review_guest_payment_refund",{p_request_id:text(formData,"request_id"),p_approve:text(formData,"decision")==="approve",p_review_note:text(formData,"note")||null});
}

export async function createPropertyAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { error: "Sign in to add a property." };
  const organizationId = text(formData, "organization_id");
  const name = text(formData, "name");
  const roomCount = Number(text(formData, "room_count"));
  const rate = nairaToKobo(text(formData, "standard_rate"));
  if (!organizationId || name.length < 2 || !Number.isInteger(roomCount) || roomCount < 1 || roomCount > 300 || rate === null) return { error: "Enter a property name, room count, and valid nightly rate." };
  const { error } = await supabase.rpc("create_property", { p_organization_id: organizationId, p_name: name, p_address: text(formData, "address"), p_room_count: roomCount, p_standard_rate_kobo: rate });
  if (error) return { error: friendlyError(error.message) };
  revalidatePath("/");
  return { success: true };
}

export async function createTeamInvitationAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { error: "Sign in to invite a team member." };
  const { data: token, error } = await supabase.rpc("create_team_invitation", {
    p_organization_id: text(formData, "organization_id"), p_property_id: text(formData, "property_id"),
    p_email: text(formData, "email"), p_role: text(formData, "role"),
  });
  if (error) return { error: friendlyError(error.message) };
  revalidatePath("/");
  return { success: true, result: String(token) };
}

export async function acceptTeamInvitationAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { error: "Sign in with the invited email address first." };
  const token = text(formData, "token");
  const { error } = await supabase.rpc("accept_team_invitation", { p_token: token });
  if (error) return { error: friendlyError(error.message) };
  revalidatePath("/");
  return { success: true };
}

export async function changeMemberRoleAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) return { error: "Sign in to change a staff role." };
  const { error } = await supabase.rpc("change_member_role", { p_organization_id: text(formData, "organization_id"), p_user_id: text(formData, "user_id"), p_role: text(formData, "role") });
  if (error) return { error: friendlyError(error.message) };
  revalidatePath("/");
  return { success: true };
}

export async function moveReservationAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const id = text(formData, "reservation_id"); const roomId = text(formData, "room_id");
  if (!id || !roomId) return { error: "Choose a destination room." };
  return runFinanceAction("move_checked_in_reservation", { p_reservation_id: id, p_to_room_id: roomId, p_reason: text(formData, "reason") || null });
}

export async function earlyCheckOutReservationAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const reservationId = text(formData, "reservation_id");
  if (!reservationId) return { error: "Reservation not found." };
  return runFinanceAction("early_check_out_reservation", { p_reservation_id: reservationId, p_actual_departure_date: text(formData, "actual_departure_date") || null });
}

export async function createBankReconciliationAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const propertyId=text(formData,"property_id"), methodId=text(formData,"payment_method_id");
  const from=text(formData,"period_from"), to=text(formData,"period_to");
  const opening=nairaToKobo(text(formData,"opening_balance")), statement=nairaToKobo(text(formData,"statement_balance"));
  if (!propertyId || !methodId || !from || !to || opening===null || statement===null) return { error: "Enter a period, payment account, and both balances." };
  const supabase=await createClient(); const { data:{user} }=await supabase.auth.getUser(); if(!user) return { error:"Sign in to reconcile an account." };
  const { data, error }=await supabase.rpc("create_bank_reconciliation",{p_property_id:propertyId,p_payment_method_id:methodId,p_from:from,p_to:to,p_opening_balance_kobo:opening,p_statement_balance_kobo:statement});
  if(error) return {error:friendlyError(error.message)}; revalidatePath("/"); return {success:true,result:String(data)};
}

export async function completeBankReconciliationAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const id=text(formData,"reconciliation_id"); if(!id) return {error:"Reconciliation not found."};
  const supabase=await createClient(); const {data:{user}}=await supabase.auth.getUser(); if(!user) return {error:"Sign in to complete a reconciliation."};
  const {data:difference,error:refreshError}=await supabase.rpc("refresh_bank_reconciliation",{p_reconciliation_id:id});
  if(refreshError) return {error:friendlyError(refreshError.message)};
  if(Number(difference)!==0) { revalidatePath("/"); return {error:`Updated balance difference is ₦${new Intl.NumberFormat("en-NG",{minimumFractionDigits:2}).format(Math.abs(Number(difference))/100)}. Correct the entries or statement, then refresh again.`}; }
  const {error}=await supabase.rpc("complete_bank_reconciliation",{p_reconciliation_id:id});
  if(error) return {error:friendlyError(error.message)}; revalidatePath("/"); return {success:true};
}

function parseCsv(value: string) {
  const rows: string[][] = []; let row: string[] = []; let cell = ""; let quoted = false;
  const input = value.replace(/^\uFEFF/, "");
  for (let index = 0; index < input.length; index += 1) {
    const character = input[index];
    if (quoted) {
      if (character === '"' && input[index + 1] === '"') { cell += '"'; index += 1; }
      else if (character === '"') quoted = false;
      else cell += character;
    } else if (character === '"') quoted = true;
    else if (character === ",") { row.push(cell); cell = ""; }
    else if (character === "\n" || character === "\r") {
      if (character === "\r" && input[index + 1] === "\n") index += 1;
      row.push(cell); cell = "";
      if (row.some(item => item.trim())) rows.push(row);
      row = [];
    } else cell += character;
  }
  if (quoted) throw new Error("The CSV contains an unclosed quoted value.");
  row.push(cell); if (row.some(item => item.trim())) rows.push(row);
  return rows;
}

function statementDate(value: string) {
  const trimmed = value.trim();
  if (/^\d{4}-\d{2}-\d{2}$/.test(trimmed)) return trimmed;
  const local = /^(\d{1,2})[\/-](\d{1,2})[\/-](\d{4})$/.exec(trimmed);
  if (!local) return null;
  const result = `${local[3]}-${local[2].padStart(2,"0")}-${local[1].padStart(2,"0")}`;
  const parsed = new Date(`${result}T00:00:00Z`);
  return Number.isNaN(parsed.getTime()) || parsed.toISOString().slice(0,10) !== result ? null : result;
}

function signedNairaToKobo(value: string) {
  let cleaned = value.trim().replace(/[₦,\s]/g, "");
  if (!cleaned) return null;
  let sign = 1;
  if (/^\(.*\)$/.test(cleaned)) { sign = -1; cleaned = cleaned.slice(1,-1); }
  if (/cr$/i.test(cleaned)) cleaned = cleaned.slice(0,-2);
  if (/dr$/i.test(cleaned)) { sign = -1; cleaned = cleaned.slice(0,-2); }
  if (cleaned.startsWith("-")) { sign = -1; cleaned = cleaned.slice(1); }
  else if (cleaned.startsWith("+")) cleaned = cleaned.slice(1);
  if (!/^\d+(?:\.\d{1,2})?$/.test(cleaned)) return null;
  const [whole,fraction=""] = cleaned.split(".");
  const amount = sign * (Number(whole)*100+Number(fraction.padEnd(2,"0")));
  return Number.isSafeInteger(amount) ? amount : null;
}

function statementLines(csv: string) {
  const rows = parseCsv(csv);
  if (rows.length < 2) throw new Error("The statement CSV needs a header and at least one transaction.");
  const headers = rows[0].map(value => value.trim().toLowerCase().replace(/[^a-z0-9]+/g,"_"));
  const column = (...names: string[]) => headers.findIndex(header => names.includes(header));
  const dateIndex = column("date","transaction_date","value_date");
  const descriptionIndex = column("description","narration","details","transaction_details");
  const referenceIndex = column("reference","ref","transaction_reference");
  const amountIndex = column("amount","transaction_amount");
  const debitIndex = column("debit","withdrawal","withdrawals");
  const creditIndex = column("credit","deposit","deposits");
  const balanceIndex = column("balance","running_balance","closing_balance");
  if (dateIndex<0 || descriptionIndex<0 || (amountIndex<0 && debitIndex<0 && creditIndex<0)) {
    throw new Error("Use date, description and amount columns, or date, description, debit and credit columns.");
  }
  if (rows.length-1>5000) throw new Error("A statement can contain at most 5,000 transaction rows.");
  return rows.slice(1).map((values,index) => {
    const date = statementDate(values[dateIndex]??"");
    const description = (values[descriptionIndex]??"").trim();
    const reference = referenceIndex<0 ? "" : (values[referenceIndex]??"").trim();
    let amount = amountIndex<0 ? null : signedNairaToKobo(values[amountIndex]??"");
    if (amountIndex<0) {
      const debit = debitIndex<0 || !(values[debitIndex]??"").trim() ? 0 : signedNairaToKobo(values[debitIndex]);
      const credit = creditIndex<0 || !(values[creditIndex]??"").trim() ? 0 : signedNairaToKobo(values[creditIndex]);
      if (debit===null || credit===null || (debit!==0 && credit!==0)) throw new Error(`Row ${index+2} must contain one valid debit or credit amount.`);
      amount = Math.abs(credit)-Math.abs(debit);
    }
    const balanceText = balanceIndex<0 ? "" : (values[balanceIndex]??"").trim();
    const balance = balanceText ? signedNairaToKobo(balanceText) : null;
    if (!date || description.length<1 || description.length>500 || reference.length>200 || amount===null || amount===0 || (balanceText && balance===null)) {
      throw new Error(`Row ${index+2} has an invalid date, description or amount.`);
    }
    return {date,description,reference:reference||null,amount_kobo:amount,balance_kobo:balance};
  });
}

export async function importBankStatementAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const reconciliationId=text(formData,"reconciliation_id"), idempotencyKey=text(formData,"idempotency_key");
  const file=formData.get("statement_file");
  if (!reconciliationId || !idempotencyKey || !(file instanceof File) || file.size===0 || !file.name.toLowerCase().endsWith(".csv")) return {error:"Choose a CSV bank statement."};
  if (file.size>2*1024*1024) return {error:"Bank statement CSV files must be 2 MB or smaller."};
  let lines: ReturnType<typeof statementLines>;
  try { lines=statementLines(await file.text()); } catch(error) { return {error:error instanceof Error?error.message:"The statement CSV could not be read."}; }
  const digest=await crypto.subtle.digest("SHA-256",await file.arrayBuffer());
  const fileHash=Array.from(new Uint8Array(digest),value=>value.toString(16).padStart(2,"0")).join("");
  const supabase=await createClient(); const {data:{user}}=await supabase.auth.getUser();
  if(!user) return {error:"Sign in to import a bank statement."};
  const {data,error}=await supabase.rpc("import_bank_statement",{p_reconciliation_id:reconciliationId,p_file_name:file.name,p_file_sha256:fileHash,p_lines:lines,p_idempotency_key:idempotencyKey});
  if(error) return {error:friendlyError(error.message)}; revalidatePath("/"); return {success:true,result:String(data)};
}

export async function autoMatchBankStatementAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  const id=text(formData,"reconciliation_id"); if(!id) return {error:"Reconciliation not found."};
  const supabase=await createClient(); const {data:{user}}=await supabase.auth.getUser(); if(!user) return {error:"Sign in to match a bank statement."};
  const {data,error}=await supabase.rpc("auto_match_bank_statement",{p_reconciliation_id:id});
  if(error) return {error:friendlyError(error.message)}; revalidatePath("/"); return {success:true,result:String(data??0)};
}

export async function matchBankStatementLineAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  return runFinanceAction("match_bank_statement_line",{p_statement_line_id:text(formData,"statement_line_id"),p_journal_id:text(formData,"journal_id"),
    p_reason:text(formData,"reason")||null,p_idempotency_key:text(formData,"idempotency_key"),p_method:"manual"});
}

export async function flagBankStatementExceptionAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  return runFinanceAction("flag_bank_statement_exception",{p_statement_line_id:text(formData,"statement_line_id"),p_reason:text(formData,"reason"),p_idempotency_key:text(formData,"idempotency_key")});
}

export async function voidBankStatementMatchAction(_previous: ActionState, formData: FormData): Promise<ActionState> {
  return runFinanceAction("void_bank_statement_match",{p_match_id:text(formData,"match_id"),p_reason:text(formData,"reason")});
}
