import { Suspense } from "react";
import { redirect } from "next/navigation";
import { HotelDashboard, type HotelContext, type LiveRoom, type LiveStay, type LiveFolio } from "@/components/hotel-dashboard";
import { createClient } from "@/lib/supabase/server";
import { hasEnvVars } from "@/lib/utils";

function first<T>(value: T | T[] | null | undefined): T | undefined {
  if (Array.isArray(value)) return value[0];
  return value ?? undefined;
}
function dateLabel(value: string) {
  return new Date(`${value}T12:00:00`).toLocaleDateString("en-NG", { month: "short", day: "numeric" });
}
function naira(kobo: number) {
  return `₦${new Intl.NumberFormat("en-NG").format(Math.round(kobo / 100))}`;
}

function HotelLoadNotice({ update = false }: { update?: boolean }) {
  return <main className="setup-page"><section className="setup-card" role="status">
    <div className="eyebrow">Coastline PMS</div>
    <h1>{update ? "Hotel update required" : "Your hotel could not be loaded"}</h1>
    <p>{update ? "Ask the hotel administrator to finish installing the PMS database update, then refresh this page." : "Try refreshing this page. If the problem continues, ask the hotel administrator to check your connection and access."}</p>
    <form action="/" method="get"><button className="button button-primary" type="submit">Refresh hotel</button></form>
  </section></main>;
}

export default function Home({ searchParams }: { searchParams: Promise<{ property?: string }> }) {
  return <Suspense fallback={<main className="setup-page"><p role="status">Loading your hotel…</p></main>}><HotelEntry searchParams={searchParams}/></Suspense>;
}

async function HotelEntry({ searchParams }: { searchParams: Promise<{ property?: string }> }) {
  const requestedPropertyId = (await searchParams).property;
  // Send one Lagos date snapshot so SSR and hydration use identical values.
  const today = new Date();
  const dayLabel = today.toLocaleDateString("en-NG", { timeZone: "Africa/Lagos", weekday: "long", day: "numeric", month: "long", year: "numeric" });
  const todayParts = new Intl.DateTimeFormat("en-CA", { timeZone: "Africa/Lagos", year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(today);
  const dateStamp = `${todayParts.find(part => part.type === "year")!.value}-${todayParts.find(part => part.type === "month")!.value}-${todayParts.find(part => part.type === "day")!.value}`;
  if (!hasEnvVars) return <HotelDashboard dayLabel={dayLabel} dateStamp={dateStamp}/>;

  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) redirect("/auth/login");

  const { data: memberships, error: membershipError } = await supabase
    .from("organization_memberships")
    .select("organization_id, role, all_properties")
    .eq("user_id", user.id)
    .eq("active", true)
    .order("created_at", { ascending: true });
  if (membershipError) return <HotelLoadNotice/>;
  if (!memberships?.length) redirect("/onboarding");

  const organizationId = memberships[0].organization_id;
  const { data: propertyRows, error: propertyError } = await supabase
    .from("properties").select("id,name").eq("organization_id", organizationId).order("created_at", { ascending: true });
  if (propertyError) return <HotelLoadNotice/>;
  let accessibleProperties = propertyRows ?? [];
  if (!memberships[0].all_properties) {
    const { data: grants, error: grantError } = await supabase.from("membership_properties")
      .select("property_id").eq("organization_id", organizationId).eq("user_id", user.id);
    if (grantError) return <HotelLoadNotice/>;
    const allowed = new Set((grants ?? []).map(row => row.property_id));
    accessibleProperties = accessibleProperties.filter(item => allowed.has(item.id));
  }
  if (!accessibleProperties.length) redirect("/onboarding");
  const property = accessibleProperties.find(item => item.id === requestedPropertyId) ?? accessibleProperties[0];

  const [{ data: roomData, error: roomsError }, { data: stayData, error: staysError },
    { data: folioData }, { data: itemData }, { data: methodData }, { data: guestData },
    { data: depositData }, { data: paymentData }, { data: expenseData }, { data: maintenanceBlocks, error: maintenanceError }, { data: departmentRows, error: departmentError }] = await Promise.all([
    supabase.from("rooms")
      .select("id,room_number,housekeeping_status,room_types(name,base_rate_kobo)")
      .eq("organization_id", organizationId).eq("property_id", property.id).eq("active", true).order("room_number"),
    supabase.from("reservations")
      .select("id,status,arrival_date,departure_date,adults,guests(full_name,phone),reservation_rooms(room_id,nightly_rate_kobo,quoted_standard_rate_kobo,pricing_reason,rooms(room_number,room_types(name))),reservation_night_rates(service_date,standard_rate_kobo,charged_rate_kobo,rate_name)")
      .eq("organization_id", organizationId).eq("property_id", property.id)
      .order("arrival_date", { ascending: false }).limit(100),
    supabase.from("folios").select("id,reservation_id,status").eq("organization_id",organizationId).eq("property_id",property.id).limit(200),
    supabase.from("folio_items").select("id,folio_id,item_type,description,service_date,total_amount_kobo")
      .eq("organization_id",organizationId).eq("property_id",property.id).order("created_at", { ascending: true }).limit(500),
    supabase.from("payment_methods").select("id,name").eq("organization_id",organizationId).eq("property_id",property.id).eq("active",true).order("name"),
    supabase.from("guests").select("id,full_name,phone,email").eq("organization_id",organizationId).order("created_at",{ascending:false}).limit(500),
    supabase.from("guest_deposits").select("id,folio_id,payment_id,amount_kobo,applied_kobo,refunded_kobo")
      .eq("organization_id",organizationId).eq("property_id",property.id).limit(500),
    supabase.from("payments").select("id,folio_id,amount_kobo,is_deposit,received_at")
      .eq("organization_id",organizationId).eq("property_id",property.id).order("received_at",{ascending:false}).limit(500),
    supabase.from("expenses").select("id,expense_date,vendor,description,amount_kobo,receipt_path")
      .eq("organization_id",organizationId).eq("property_id",property.id).order("expense_date",{ascending:false}).limit(50),
    supabase.from("rooms").select("id,maintenance_work_orders!inner(id)")
      .eq("organization_id",organizationId).eq("property_id",property.id)
      .eq("maintenance_work_orders.blocks_inventory",true).in("maintenance_work_orders.status",["open","in_progress"]),
    supabase.from("departments").select("id,code,name").eq("organization_id",organizationId).eq("property_id",property.id).eq("active",true).order("name"),
  ]);
  if (departmentError) return <HotelLoadNotice update={["42P01", "PGRST205", "PGRST200"].includes(departmentError.code)}/>;
  if (maintenanceError) return <HotelLoadNotice update={["42P01", "PGRST205", "PGRST200"].includes(maintenanceError.code)}/>;
  const blockedRoomIds = new Set((maintenanceBlocks ?? []).map(order => order.id));
  if (roomsError || staysError) return <HotelLoadNotice update={["42P01", "PGRST205", "PGRST200", "42703"].includes((roomsError ?? staysError)!.code)}/>;

  const rooms: LiveRoom[] = (roomData ?? []).map((raw) => {
    const room = raw as unknown as { id: string; room_number: string; housekeeping_status: string; room_types: { name: string; base_rate_kobo: number } | { name: string; base_rate_kobo: number }[] | null };
    const type = first(room.room_types);
    return { id: room.id, number: room.room_number, status: room.housekeeping_status, type: type?.name ?? "Room", rateKobo: Number(type?.base_rate_kobo ?? 0), maintenanceBlocked: blockedRoomIds.has(room.id) };
  });
  const stays: LiveStay[] = (stayData ?? []).map((raw) => {
    const stay = raw as unknown as { reservation_night_rates: { service_date: string; standard_rate_kobo: number; charged_rate_kobo: number; rate_name: string }[]; id: string; status: LiveStay["status"]; arrival_date: string; departure_date: string; adults: number; guests: { full_name: string; phone: string | null } | { full_name: string; phone: string | null }[] | null; reservation_rooms: { room_id: string; nightly_rate_kobo: number; quoted_standard_rate_kobo: number | null; pricing_reason: string | null; rooms: { room_number: string; room_types: { name: string } | { name: string }[] | null } | { room_number: string; room_types: { name: string } | { name: string }[] | null }[] | null }[] };
    const guest = first(stay.guests);
    const allocation = stay.reservation_rooms?.[0];
    const assignedRoom = allocation ? first(allocation.rooms) : undefined;
    const roomType = assignedRoom ? first(assignedRoom.room_types) : undefined;
    const nights = Math.max(1, Math.round((new Date(`${stay.departure_date}T12:00:00`).getTime() - new Date(`${stay.arrival_date}T12:00:00`).getTime()) / 86400000));
    const nightRates = (stay.reservation_night_rates ?? []).filter(night => night.service_date >= stay.arrival_date && night.service_date < stay.departure_date)
      .sort((a,b) => a.service_date.localeCompare(b.service_date)).map(night => ({ date: night.service_date, standardKobo: Number(night.standard_rate_kobo), agreedKobo: Number(night.charged_rate_kobo), rateName: night.rate_name }));
    if (allocation && nightRates.length !== nights) throw new Error("Some agreed nightly prices are missing. Ask the hotel administrator to review the stay.");
    const initials = (guest?.full_name ?? "Guest").split(/\s+/).slice(0, 2).map(part => part[0] ?? "").join("").toUpperCase();
    return {
      id: stay.id, guest: guest?.full_name ?? "Guest", initials, phone: guest?.phone ?? "",
      roomId: allocation?.room_id ?? "", room: assignedRoom ? `${assignedRoom.room_number} · ${roomType?.name ?? "Room"}` : "Unassigned",
      arrivalDate: stay.arrival_date, departureDate: stay.departure_date,
      arrival: dateLabel(stay.arrival_date), departure: dateLabel(stay.departure_date),
      amount: naira(nightRates.reduce((sum,night) => sum + night.agreedKobo,0)), nightRates,
      status: stay.status, housekeepingStatus: "",
      standardRateKobo: allocation?.quoted_standard_rate_kobo == null ? undefined : Number(allocation.quoted_standard_rate_kobo),
      nightlyRateKobo: nightRates.every(night => night.agreedKobo === nightRates[0]?.agreedKobo) ? nightRates[0]?.agreedKobo : undefined,
      complimentary: nightRates.length > 0 && nightRates.every(night => night.agreedKobo === 0), pricingReason: allocation?.pricing_reason ?? undefined,
    };
  });

  const folios: LiveFolio[] = (folioData ?? []).map(row => ({
    id: row.id, reservationId: row.reservation_id, status: row.status,
    items: (itemData ?? []).filter(item => item.folio_id === row.id).map(item => ({
      id: item.id, type: item.item_type, description: item.description,
      serviceDate: item.service_date, totalKobo: Number(item.total_amount_kobo),
    })),
  }));
  const financeAllowed = ["owner","manager","accountant"].includes(memberships[0].role);
  const localToday = dateStamp;
  const monthStart = `${localToday.slice(0,7)}-01`;
  const finance = { ready: false, roomRevenueKobo: 0, otherRevenueKobo: 0, expenseKobo: 0, paymentsKobo: 0,
    outstandingKobo: 0, roomNights: 0, monthStart,
    entries: [] as { id: string; date: string; memo: string; source: string; amountKobo: number }[] };
  if (financeAllowed) {
    const { data: summary, error: summaryError } = await supabase.rpc("get_property_financial_summary", {
      p_property_id: property.id, p_from: monthStart, p_to: localToday,
    });
    if (!summaryError) {
      const totals = Array.isArray(summary) ? summary[0] : summary;
      finance.ready = true;
      finance.roomRevenueKobo = Number(totals?.room_revenue_kobo ?? 0);
      finance.otherRevenueKobo = Number(totals?.other_revenue_kobo ?? 0);
      finance.expenseKobo = Number(totals?.expense_kobo ?? 0);
      finance.paymentsKobo = Number(totals?.payments_kobo ?? 0);
      finance.outstandingKobo = Number(totals?.outstanding_kobo ?? 0);
      finance.roomNights = Number(totals?.room_nights ?? 0);
      const { data: journals, error: journalError } = await supabase.from("journals")
        .select("id,journal_date,memo,source_type").eq("organization_id",organizationId).eq("property_id",property.id)
        .eq("status","posted").gte("journal_date",monthStart).lte("journal_date",localToday)
        .order("journal_date",{ ascending: false }).limit(12);
      if (journalError) throw new Error("Could not load recent financial journals.");
      const ids = (journals ?? []).map(journal => journal.id);
      const { data: lines, error: lineError } = ids.length ? await supabase.from("journal_lines")
        .select("journal_id,debit_kobo").eq("organization_id",organizationId).eq("property_id",property.id)
        .in("journal_id",ids).limit(50) : { data: [], error: null };
      if (lineError) throw new Error("Could not load recent journal amounts.");
      finance.entries = (journals ?? []).map(journal => ({
        id: journal.id, date: journal.journal_date, memo: journal.memo, source: journal.source_type,
        amountKobo: (lines ?? []).filter(line => line.journal_id === journal.id)
          .reduce((sum,line) => sum + Number(line.debit_kobo),0),
      }));
    } else if (summaryError.code !== "PGRST202" && summaryError.code !== "42883") {
      throw new Error(`Could not load the financial summary: ${summaryError.message}`);
    }
  }

  const { data: teamRows } = memberships[0].role === "owner"
    ? await supabase.rpc("get_team_members", { p_organization_id: organizationId })
    : { data: [] };
  const context: HotelContext = {
    organizationId,
    properties: accessibleProperties.map(item => ({ id: item.id, name: item.name })),
    teamMembers: (teamRows ?? []).map((item: { user_id: string; email: string | null; role: string; active: boolean }) => ({ userId: item.user_id, email: item.email ?? "", role: item.role, active: item.active })),
    propertyId: property.id,
    propertyName: property.name,
    ownerName: user.user_metadata.full_name || user.email?.split("@")[0] || "Hotel team",
    role: memberships[0].role,
    expenses: (expenseData ?? []).map(expense => ({ id: expense.id, date: expense.expense_date,
      vendor: expense.vendor ?? "", description: expense.description, amountKobo: Number(expense.amount_kobo), receiptPath: expense.receipt_path ?? "" })),
    rooms,
    stays,
    folios,
    departments: departmentRows ?? [],
    paymentMethods: (methodData ?? []).map(method => ({ id: method.id, name: method.name })),
    guests: (guestData ?? []).map(guest => ({ id: guest.id, name: guest.full_name,
      phone: guest.phone ?? "", email: guest.email ?? "" })),
    deposits: (depositData ?? []).map(deposit => ({ id: deposit.id, folioId: deposit.folio_id,
      paymentId: deposit.payment_id, amountKobo: Number(deposit.amount_kobo),
      appliedKobo: Number(deposit.applied_kobo), refundedKobo: Number(deposit.refunded_kobo) })),
    payments: (paymentData ?? []).map(payment => ({ id: payment.id, folioId: payment.folio_id,
      amountKobo: Number(payment.amount_kobo), isDeposit: payment.is_deposit ?? false,
      receivedAt: payment.received_at })),
    finance,
  };
  return <HotelDashboard context={context} dayLabel={dayLabel} dateStamp={dateStamp}/>;
}
