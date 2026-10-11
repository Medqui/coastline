"use client";

import { useEffect, useState } from "react";
import { ArrowDownToLine, ArrowRight, BarChart3, BedDouble, Building2, CalendarDays, ChevronDown, CircleDollarSign, LoaderCircle, Percent, Plus, RefreshCw, Users, Wallet } from "lucide-react";
import { createClient } from "@/lib/supabase/client";
import { readWithRetry } from "@/lib/supabase/read-with-retry";
import { hasFeature } from "@/lib/saas/types";
import { FeatureGate } from "@/components/feature-gate";
import type { HotelContext } from "@/components/hotel-dashboard";
import { OccupancyTrend, RoomDistribution, type OccupancyPoint, type RoomTypeCount } from "@/components/dashboard-visuals";

type Property = { id: string; name: string };
type Navigate = (screen: "Reservations" | "Front Desk" | "Rooms" | "Accounting" | "Reports") => void;
type Reservation = {
  id: string; status: string; source: string | null; arrival_date: string; departure_date: string; created_at: string;
  reservation_rooms: { room_id: string; nightly_rate_kobo: number; rooms: { room_types: { name: string } | { name: string }[] | null } | { room_types: { name: string } | { name: string }[] | null }[] | null }[];
};
type Folio = { id: string; reservation_id: string };
type FolioItem = { folio_id: string; item_type: string; total_amount_kobo: number; service_date: string };
type Room = { id: string; active: boolean; room_types: { name: string } | { name: string }[] | null };
type Department = { department_name: string; revenue_kobo: number; expense_kobo: number; net_income_kobo: number };
type AgingSummary = { outstanding_kobo: number; age_0_30_kobo: number; age_31_60_kobo: number; age_61_90_kobo: number; age_90_plus_kobo: number };
type SupplierSummary = { outstanding_kobo: number; current_kobo: number; overdue_1_30_kobo: number; overdue_31_60_kobo: number; overdue_61_90_kobo: number; overdue_90_plus_kobo: number };
type Metrics = {
  revenueKobo: number; roomRevenueKobo: number; expenseKobo: number; profitKobo: number;
  actualOccupancy: number; forecastOccupancy: number; adrKobo: number; revparKobo: number;
  occupiedRoomNights: number; forecastRoomNights: number; availableRoomNights: number;
  averageStayNights: number; bookingLeadDays: number; cancellationRate: number; noShowRate: number;
  byRoomType: { name: string; amountKobo: number }[]; bySource: { name: string; amountKobo: number }[];
  departments: Department[]; receivables?: AgingSummary; payables?: SupplierSummary;
  occupancyTrend: OccupancyPoint[]; roomTypes: RoomTypeCount[];
};
type LoadedData = { metrics: Metrics; propertyId: string };

const first = <T,>(value: T | T[] | null | undefined): T | undefined => Array.isArray(value) ? value[0] : value ?? undefined;
const money = (kobo: number) => `₦${new Intl.NumberFormat("en-NG").format(Math.round(kobo / 100))}`;
const moneyDecimal = (kobo: number) => `₦${new Intl.NumberFormat("en-NG", { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(kobo / 100)}`;
const dateLabel = (date: string) => new Date(`${date}T12:00:00Z`).toLocaleDateString("en-NG", { day: "numeric", month: "short", timeZone: "Africa/Lagos" });
const percentage = (value: number) => `${(value * 100).toFixed(1)}%`;
const dateOffset = (date: string, days: number) => { const value = new Date(`${date}T12:00:00Z`); value.setUTCDate(value.getUTCDate() + days); return value.toISOString().slice(0, 10); };
const daysBetween = (from: string, to: string) => Math.max(1, Math.round((new Date(`${to}T12:00:00Z`).getTime() - new Date(`${from}T12:00:00Z`).getTime()) / 86400000));
const dateInLagos = (value: string) => new Date(value).toLocaleDateString("en-CA", { timeZone: "Africa/Lagos" });

function sumBy(rows: { name: string; amountKobo: number }[]) {
  const totals = new Map<string, number>();
  rows.forEach(row => totals.set(row.name, (totals.get(row.name) ?? 0) + row.amountKobo));
  return [...totals.entries()].map(([name, amountKobo]) => ({ name, amountKobo })).sort((a, b) => b.amountKobo - a.amountKobo);
}

async function loadMetrics(propertyId: string, from: string, to: string, includeAging: boolean, includeAdvanced: boolean): Promise<Metrics> {
  const db = createClient();
  const [reservationResult, folioResult, itemResult, roomResult, pnlResult, departmentResult, agingResult, payablesResult, expenseResult] = await Promise.all([
    readWithRetry(() => db.from("reservations").select("id,status,source,arrival_date,departure_date,created_at,reservation_rooms(room_id,nightly_rate_kobo,rooms(room_types(name)))").eq("property_id", propertyId).order("arrival_date", { ascending: true }).limit(5000)),
    readWithRetry(() => db.from("folios").select("id,reservation_id").eq("property_id", propertyId).limit(5000)),
    readWithRetry(() => db.from("folio_items").select("folio_id,item_type,total_amount_kobo,service_date").eq("property_id", propertyId).gte("service_date", from).lte("service_date", to).limit(10000)),
    readWithRetry(() => db.from("rooms").select("id,active,room_types(name)").eq("property_id", propertyId)),
    readWithRetry(() => db.rpc("get_profit_and_loss", { p_property_id: propertyId, p_from: from, p_to: to })),
    includeAdvanced ? readWithRetry(() => db.rpc("get_department_profit_and_loss", { p_property_id: propertyId, p_from: from, p_to: to })) : Promise.resolve({ data: [], error: null }),
    includeAging ? readWithRetry(() => db.rpc("get_guest_receivables_summary", { p_property_id: propertyId, p_as_of: to })) : Promise.resolve({ data: [], error: null }),
    includeAging ? readWithRetry(() => db.rpc("get_supplier_payables_summary", { p_property_id: propertyId, p_as_of: to })) : Promise.resolve({ data: [], error: null }),
    readWithRetry(() => db.from("expenses").select("amount_kobo").eq("property_id", propertyId).eq("status", "posted").gte("expense_date", from).lte("expense_date", to).limit(5000)),
  ]);
  const failed = [reservationResult, folioResult, itemResult, roomResult, pnlResult, departmentResult, expenseResult].find(result => result.error);
  if (failed?.error) throw new Error("Owner dashboard data could not be loaded. Try refreshing the dashboard.");

  const reservations = (reservationResult.data ?? []) as unknown as Reservation[];
  const folios = (folioResult.data ?? []) as Folio[];
  const items = (itemResult.data ?? []) as FolioItem[];
  const rooms = (roomResult.data ?? []) as unknown as Room[];
  const folioReservation = new Map(folios.map(folio => [folio.id, folio.reservation_id]));
  const reservationsById = new Map(reservations.map(reservation => [reservation.id, reservation]));
  const roomRevenueItems = items.filter(item => item.item_type === "room_charge");
  const allRevenueItems = items.filter(item => ["room_charge", "extra"].includes(item.item_type));
  const roomRevenueKobo = roomRevenueItems.reduce((sum, item) => sum + Number(item.total_amount_kobo), 0);
  const revenueFromItems = allRevenueItems.reduce((sum, item) => sum + Number(item.total_amount_kobo), 0);
  const pnl = (pnlResult.data ?? []) as { account_type: string; amount_kobo: number }[];
  const revenueKobo = pnl.filter(row => row.account_type === "revenue").reduce((sum, row) => sum + Number(row.amount_kobo), 0) || revenueFromItems;
  const expenseFromPnl = pnl.filter(row => row.account_type === "expense").reduce((sum, row) => sum + Number(row.amount_kobo), 0);
  const expenseKobo = expenseFromPnl || (expenseResult.data ?? []).reduce((sum, row: { amount_kobo: number }) => sum + Number(row.amount_kobo), 0);
  const relevant = reservations.filter(reservation => reservation.arrival_date < dateOffset(to, 1) && reservation.departure_date > from);
  const completedOrInHouse = relevant.filter(reservation => ["checked_in", "checked_out"].includes(reservation.status));
  const forecastable = relevant.filter(reservation => ["confirmed", "checked_in", "checked_out"].includes(reservation.status));
  const dayCount = daysBetween(from, dateOffset(to, 1));
  const activeRooms = rooms.filter(room => room.active).length;
  const roomNights = (stays: Reservation[]) => stays.reduce((sum, stay) => {
    const start = stay.arrival_date > from ? stay.arrival_date : from;
    const end = stay.departure_date < dateOffset(to, 1) ? stay.departure_date : dateOffset(to, 1);
    return sum + Math.max(0, daysBetween(start, end));
  }, 0);
  const occupiedRoomNights = roomNights(completedOrInHouse);
  const forecastRoomNights = roomNights(forecastable);
  const availableRoomNights = activeRooms * dayCount;
  const stayNights = completedOrInHouse.reduce((sum, stay) => sum + daysBetween(stay.arrival_date, stay.departure_date), 0);
  const stayCount = completedOrInHouse.length;
  const bookingLeadDays = relevant.length ? relevant.reduce((sum, stay) => sum + Math.max(0, Math.round((new Date(`${stay.arrival_date}T12:00:00Z`).getTime() - new Date(dateInLagos(stay.created_at) + "T12:00:00Z").getTime()) / 86400000)), 0) / relevant.length : 0;
  const denominator = reservations.length || 1;
  const cancellationRate = reservations.filter(reservation => reservation.status === "cancelled").length / denominator;
  const noShowRate = reservations.filter(reservation => reservation.status === "no_show").length / denominator;
  const roomTypeRows: { name: string; amountKobo: number }[] = [];
  const sourceRows: { name: string; amountKobo: number }[] = [];
  allRevenueItems.forEach(item => {
    const reservation = reservationsById.get(folioReservation.get(item.folio_id) ?? "");
    if (!reservation) return;
    const allocation = first(reservation.reservation_rooms);
    const roomType = first(first(allocation?.rooms)?.room_types)?.name ?? "Unassigned";
    roomTypeRows.push({ name: roomType, amountKobo: Number(item.total_amount_kobo) });
    sourceRows.push({ name: reservation.source || "direct", amountKobo: Number(item.total_amount_kobo) });
  });
  const departmentRows = (departmentResult.data ?? []) as Department[];
  const aging = first((agingResult.data ?? []) as AgingSummary[]);
  const payables = first((payablesResult.data ?? []) as SupplierSummary[]);
  const occupancyTrend = Array.from({ length: dayCount }, (_, index) => {
    const date = dateOffset(from, index);
    const onDate = relevant.filter(stay => stay.arrival_date <= date && stay.departure_date > date);
    return { date,
      occupied: activeRooms ? onDate.filter(stay => ["checked_in", "checked_out"].includes(stay.status)).length / activeRooms * 100 : 0,
      booked: activeRooms ? onDate.filter(stay => ["confirmed", "checked_in", "checked_out"].includes(stay.status)).length / activeRooms * 100 : 0,
    };
  });
  const roomTypes = new Map<string, number>();
  rooms.filter(room => room.active).forEach(room => {
    const name = first(room.room_types)?.name ?? "Unassigned";
    roomTypes.set(name, (roomTypes.get(name) ?? 0) + 1);
  });
  return {
    revenueKobo, roomRevenueKobo, expenseKobo, profitKobo: revenueKobo - expenseKobo,
    actualOccupancy: availableRoomNights ? occupiedRoomNights / availableRoomNights : 0,
    forecastOccupancy: availableRoomNights ? forecastRoomNights / availableRoomNights : 0,
    adrKobo: occupiedRoomNights ? roomRevenueKobo / occupiedRoomNights : 0,
    revparKobo: availableRoomNights ? roomRevenueKobo / availableRoomNights : 0,
    occupiedRoomNights, forecastRoomNights, availableRoomNights,
    averageStayNights: stayCount ? stayNights / stayCount : 0,
    bookingLeadDays, cancellationRate, noShowRate,
    byRoomType: sumBy(roomTypeRows), bySource: sumBy(sourceRows), departments: departmentRows,
    receivables: aging, payables,
    occupancyTrend, roomTypes: [...roomTypes].map(([name, count]) => ({ name, count })),
  };
}

function Card({ label, value, note, icon: Icon, onClick }: { label: string; value: string; note: string; icon: typeof BedDouble; onClick?: () => void }) {
  return <button className={`owner-kpi ${onClick ? "owner-kpi-clickable" : ""}`} onClick={onClick} type="button"><span className="owner-kpi-label">{label}<i><Icon size={16}/></i></span><strong>{value}</strong><small>{note}</small></button>;
}

function Breakdown({ title, rows, format = money }: { title: string; rows: { name: string; amountKobo: number }[]; format?: (value: number) => string }) {
  const max = Math.max(...rows.map(row => row.amountKobo), 1);
  return <section className="owner-breakdown panel"><div className="panel-heading"><strong>{title}</strong></div>{rows.length ? <div className="owner-breakdown-list">{rows.slice(0, 8).map(row => <div className="owner-breakdown-row" key={row.name}><div><span>{row.name.replaceAll("_", " ")}</span><b>{format(row.amountKobo)}</b></div><i><em style={{ width: `${Math.max(3, row.amountKobo / max * 100)}%` }}/></i></div>)}</div> : <p className="empty-state">No data in this period.</p>}</section>;
}

function AgingCard({ title, values, labels }: { title: string; values?: number[]; labels: string[] }) {
  return <section className="owner-aging panel"><div className="panel-heading"><strong>{title}</strong></div><div className="owner-aging-grid">{labels.map((label, index) => <div key={label}><span>{label}</span><b>{money(values?.[index] ?? 0)}</b></div>)}</div></section>;
}

export function OwnerDashboard({ context, dateStamp, navigate, openReservation }: { context: HotelContext; dateStamp: string; navigate: Navigate; openReservation: () => void }) {
  const advanced = hasFeature(context.subscription, "advanced_reports");
  const multiProperty = hasFeature(context.subscription, "multi_property");
  const defaultFrom = `${dateStamp.slice(0, 7)}-01`;
  const [from, setFrom] = useState(defaultFrom); const [to, setTo] = useState(dateStamp);
  const [period, setPeriod] = useState("month");
  const [data, setData] = useState<LoadedData>(); const [comparison, setComparison] = useState<{ property: Property; metrics: Metrics }[]>([]);
  const [loading, setLoading] = useState(true); const [error, setError] = useState(""); const [refresh, setRefresh] = useState(0);
  const property = context.properties.find(item => item.id === context.propertyId) ?? context.properties[0];
  const choosePeriod = (value: string) => {
    setPeriod(value);
    if (value === "custom") return;
    setFrom(value === "today" ? dateStamp : value === "week" ? dateOffset(dateStamp, -6) : defaultFrom);
    setTo(dateStamp);
  };
  const todayStays = context.stays.filter(stay => (stay.status === "confirmed" && stay.arrivalDate <= dateStamp) || (stay.status === "checked_in" && stay.departureDate <= dateStamp))
    .sort((a, b) => a.arrivalDate.localeCompare(b.arrivalDate));
  const arrivals = todayStays.filter(stay => stay.status === "confirmed").length;
  const departures = todayStays.length - arrivals;
  useEffect(() => {
    let active = true;
    if (!from || !to || to < from) { setError("Choose a valid dashboard period."); setLoading(false); return; }
    setLoading(true); setError("");
    Promise.all([loadMetrics(property.id, from, to, advanced, advanced), ...(multiProperty ? context.properties : []).map(item => loadMetrics(item.id, from, to, false, advanced).then(metrics => ({ property: item, metrics })))])
      .then(([current, ...others]) => { if (!active) return; setData({ metrics: current as Metrics, propertyId: property.id }); setComparison(others as { property: Property; metrics: Metrics }[]); setLoading(false); })
      .catch(() => { if (active) { setData(undefined); setComparison([]); setLoading(false); setError("Owner dashboard data could not be loaded. Try refreshing the dashboard."); } });
    return () => { active = false; };
  }, [context.properties, from, to, property.id, refresh, advanced, multiProperty]);
  const metrics = data?.propertyId === property.id ? data.metrics : undefined;
  const exportCsv = () => {
    if (!metrics) return;
    const rows = [["Metric", "Value"], ["Period", `${from} to ${to}`], ["Property", property.name], ["Revenue", money(metrics.revenueKobo)], ["Room revenue", money(metrics.roomRevenueKobo)], ["Operating expenses", money(metrics.expenseKobo)], ["Operating profit", money(metrics.profitKobo)], ["Actual occupancy", percentage(metrics.actualOccupancy)], ["Forecast occupancy", percentage(metrics.forecastOccupancy)], ["ADR", moneyDecimal(metrics.adrKobo)], ["RevPAR", moneyDecimal(metrics.revparKobo)], ["Average stay", `${metrics.averageStayNights.toFixed(1)} nights`], ["Booking lead time", `${metrics.bookingLeadDays.toFixed(1)} days`], ["Cancellation rate", percentage(metrics.cancellationRate)], ["No-show rate", percentage(metrics.noShowRate)]];
    const csv = rows.map(row => row.map(value => `"${String(value).replaceAll('"', '""')}"`).join(",")).join("\r\n");
    const url = URL.createObjectURL(new Blob(["\uFEFF", csv], { type: "text/csv;charset=utf-8" })); const link = document.createElement("a"); link.href = url; link.download = `owner-dashboard-${from}-${to}.csv`; link.click(); URL.revokeObjectURL(url);
  };
  return <div className="dashboard-overview">
    <div className="owner-heading"><div><div className="eyebrow">HOTEL OVERVIEW</div><h1>Dashboard</h1><p>A clear view of performance and what needs your attention.</p></div><div className="heading-actions"><button className="button" onClick={() => setRefresh(value => value + 1)} aria-label="Refresh dashboard"><RefreshCw size={15}/><span>Refresh</span></button><button className="button" onClick={exportCsv} disabled={!metrics || loading}><ArrowDownToLine size={15}/>Export</button><button className="button button-primary" onClick={openReservation}><Plus size={16}/>New reservation</button></div></div>
    <div className="dashboard-toolbar"><div className="period-tabs" role="group" aria-label="Dashboard period">{[{ value: "today", label: "Today" }, { value: "week", label: "Last 7 days" }, { value: "month", label: "This month" }, { value: "custom", label: "Custom" }].map(item => <button key={item.value} aria-pressed={period === item.value} className={period === item.value ? "active" : ""} onClick={() => choosePeriod(item.value)}>{item.label}</button>)}</div>{period === "custom" ? <div className="owner-controls"><label>From<input type="date" value={from} max={to} onChange={event => setFrom(event.target.value)}/></label><label>To<input type="date" value={to} min={from} onChange={event => setTo(event.target.value)}/></label></div> : <span className="dashboard-period-label"><CalendarDays size={15}/>{from === to ? dateLabel(from) : `${dateLabel(from)} – ${dateLabel(to)}`}</span>}</div>
    {loading && <section className="panel owner-loading" role="status"><LoaderCircle className="spin" size={18}/>Loading hotel performance…</section>}
    {error && <section className="form-error owner-error" role="alert">{error}</section>}
    {metrics && !loading && <>
      <div className="owner-kpi-grid"><Card label="Total revenue" value={money(metrics.revenueKobo)} note="Posted income in this period" icon={CircleDollarSign} onClick={() => navigate("Accounting")}/><Card label="Operating profit" value={money(metrics.profitKobo)} note="Revenue less operating expenses" icon={Wallet} onClick={() => navigate("Accounting")}/><Card label="Room occupancy" value={percentage(metrics.actualOccupancy)} note={`${metrics.occupiedRoomNights} occupied room nights`} icon={BedDouble} onClick={() => navigate("Rooms")}/><Card label="Average daily rate" value={moneyDecimal(metrics.adrKobo)} note="Average revenue per occupied night" icon={BarChart3} onClick={() => navigate("Accounting")}/></div>
      <div className="dashboard-main-grid"><OccupancyTrend points={metrics.occupancyTrend} note="Occupied and booked rooms · selected period"/><RoomDistribution rooms={metrics.roomTypes}/></div>
    </>}
    <div className="dashboard-main-grid dashboard-today-grid"><section className="panel"><div className="card-heading"><div><strong>Today’s arrivals & departures</strong><small>{arrivals} arrivals · {departures} departures due</small></div><button className="text-button" onClick={() => navigate("Front Desk")}>Front desk<ArrowRight size={15}/></button></div>{todayStays.length ? <div className="table-wrap"><table><thead><tr><th>Guest</th><th>Room</th><th>Stay dates</th><th>Status</th></tr></thead><tbody>{todayStays.slice(0, 5).map(stay => <tr key={stay.id}><td><span className="guest-name"><i>{stay.initials}</i>{stay.guest}</span></td><td>{stay.room}</td><td>{dateLabel(stay.arrivalDate)} – {dateLabel(stay.departureDate)}</td><td><span className={`status-pill ${stay.status === "confirmed" ? "green-pill" : "amber-pill"}`}>{stay.status === "confirmed" ? "Arriving" : "Due out"}</span></td></tr>)}</tbody></table>{todayStays.length > 5 && <button className="text-button dashboard-view-all" onClick={() => navigate("Front Desk")}>View all {todayStays.length} stays<ArrowRight size={14}/></button>}</div> : <p className="empty-state">No arrivals or departures due today.</p>}</section>
      <section className="panel"><div className="card-heading"><div><strong>Needs attention</strong><small>Quick links to your next tasks</small></div></div><div className="dashboard-task-list"><button onClick={() => navigate("Front Desk")}><span className="dashboard-task-icon"><CalendarDays size={17}/></span><span><strong>Welcome arriving guests</strong><small>{arrivals} reservations ready to review</small></span><ArrowRight size={16}/></button><button onClick={() => navigate("Front Desk")}><span className="dashboard-task-icon amber"><Users size={17}/></span><span><strong>Review departures</strong><small>{departures} guests due to check out</small></span><ArrowRight size={16}/></button><button onClick={() => navigate("Reports")}><span className="dashboard-task-icon"><Wallet size={17}/></span><span><strong>Guest balances</strong><small>{loading ? "Loading balances…" : metrics?.receivables ? `${money(metrics.receivables.outstanding_kobo)} outstanding at period end` : "View the latest balance report"}</small></span><ArrowRight size={16}/></button></div></section></div>
    {metrics && !loading && <FeatureGate subscription={context.subscription} feature="advanced_reports" organizationId={context.organizationId}><details className="dashboard-details"><summary><span><strong>Detailed performance & reports</strong><small>Forecasts, revenue breakdowns and outstanding balances</small></span><ChevronDown size={18}/></summary><div className="dashboard-details-content">
      <div className="owner-kpi-grid"><Card label="Forecast occupancy" value={percentage(metrics.forecastOccupancy)} note={`${metrics.forecastRoomNights} booked / in-house nights`} icon={CalendarDays} onClick={() => navigate("Reservations")}/><Card label="Revenue per available room" value={moneyDecimal(metrics.revparKobo)} note="Room revenue ÷ available nights" icon={Percent} onClick={() => navigate("Rooms")}/><Card label="Guest receivables" value={metrics.receivables ? money(metrics.receivables.outstanding_kobo) : "Unavailable"} note="Outstanding as of period end" icon={Users} onClick={() => navigate("Reports")}/><Card label="Supplier payables" value={metrics.payables ? money(metrics.payables.outstanding_kobo) : "Unavailable"} note="Outstanding as of period end" icon={Building2} onClick={() => navigate("Accounting")}/></div>
      <div className="owner-insight-grid"><section className="owner-detail panel"><div className="panel-heading"><div><strong>Demand and stay quality</strong><small>{property.name} · {from} to {to}</small></div></div><div className="owner-stat-grid"><div><span>Average length of stay</span><b>{metrics.averageStayNights.toFixed(1)} nights</b></div><div><span>Booking lead time</span><b>{metrics.bookingLeadDays.toFixed(1)} days</b></div><div><span>Cancellation rate</span><b>{percentage(metrics.cancellationRate)}</b></div><div><span>No-show rate</span><b>{percentage(metrics.noShowRate)}</b></div><div><span>Available room nights</span><b>{metrics.availableRoomNights}</b></div><div><span>Room revenue</span><b>{money(metrics.roomRevenueKobo)}</b></div></div></section><FeatureGate subscription={context.subscription} feature="multi_property" organizationId={context.organizationId}><section className="owner-detail panel"><div className="panel-heading"><div><strong>Property comparison</strong><small>Same date range across accessible properties</small></div></div><div className="table-wrap"><table><thead><tr><th>Property</th><th>Revenue</th><th>Occupancy</th><th>RevPAR</th></tr></thead><tbody>{comparison.map(item => <tr key={item.property.id}><td>{item.property.name}</td><td>{money(item.metrics.revenueKobo)}</td><td>{percentage(item.metrics.actualOccupancy)}</td><td>{moneyDecimal(item.metrics.revparKobo)}</td></tr>)}</tbody></table></div></section></FeatureGate></div>
      <div className="owner-breakdown-grid"><Breakdown title="Room revenue by room type" rows={metrics.byRoomType}/><Breakdown title="Revenue by booking source" rows={metrics.bySource}/><Breakdown title="Department revenue" rows={metrics.departments.map(row => ({ name: row.department_name, amountKobo: Number(row.revenue_kobo) }))}/></div>
      <div className="owner-aging-grid-wrap"><AgingCard title="Guest receivables aging" values={[metrics.receivables?.outstanding_kobo ?? 0, metrics.receivables?.age_0_30_kobo ?? 0, metrics.receivables?.age_31_60_kobo ?? 0, metrics.receivables?.age_61_90_kobo ?? 0, metrics.receivables?.age_90_plus_kobo ?? 0]} labels={["Outstanding", "0–30 days", "31–60 days", "61–90 days", "90+ days"]}/><AgingCard title="Supplier payable aging" values={[metrics.payables?.outstanding_kobo ?? 0, metrics.payables?.current_kobo ?? 0, metrics.payables?.overdue_1_30_kobo ?? 0, metrics.payables?.overdue_31_60_kobo ?? 0, metrics.payables?.overdue_90_plus_kobo ?? 0]} labels={["Outstanding", "Current", "1–30 overdue", "31–60 overdue", "90+ overdue"]}/></div>
      <p className="owner-footnote">Actual occupancy counts checked-in and checked-out stays; forecast occupancy also includes confirmed stays. ADR and RevPAR use posted room revenue. Operating profit is posted revenue less posted operating expenses.</p>
    </div></details></FeatureGate>}
  </div>;
}
