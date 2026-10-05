"use client";

import { useEffect, useState } from "react";
import {
  Activity, ArrowDownToLine, ArrowDownUp, ArrowRight, ArrowUpRight, BedDouble,
  Bell, CalendarDays, Check, ChevronDown, CircleDollarSign, ClipboardList,
  DoorOpen, LayoutDashboard, Menu, Plus, Search, Settings2, Sparkles, Users,
  Wallet, X, ShoppingCart, Package, BarChart3,
} from "lucide-react";
import { CheckInAction } from "@/components/check-in-action";
import { RoomStatusAction } from "@/components/room-status-action";
import { ReservationDialog } from "@/components/reservation-dialog";
import { FolioDialog } from "@/components/folio-dialog";
import { ExpenseForm } from "@/components/expense-form";
import { CloseReservationDialog } from "@/components/close-reservation-dialog";
import { DepositDialog } from "@/components/deposit-dialog";
import { AdminPanel } from "@/components/admin-panel";
import { RoomMoveControl } from "@/components/room-move-control";
import { EarlyCheckoutAction } from "@/components/early-checkout-action";
import { FinancialReports } from "@/components/financial-reports";
import { ExpenseList } from "@/components/expense-list";
import { MaintenancePanel } from "@/components/maintenance-panel";
import { PropertySettings } from "@/components/property-settings";
import { InventoryPanel } from "@/components/inventory-panel";
import { StaffShiftPanel } from "@/components/staff-shift-panel";
import { canViewScreen, parseScreen, roomState, screenHash, type Screen, type RoomState } from "@/lib/pms-navigation";
import { SupplierAccountsPanel } from "@/components/supplier-accounts-panel";
import { AvailabilityCalendar } from "@/components/availability-calendar";
import { LogoutButton } from "@/components/logout-button";
import { CashierControls } from "@/components/cashier-controls";

export type LiveRoom = { id: string; number: string; status: string; type: string; rateKobo: number; maintenanceBlocked?: boolean };
export type LiveStay = {
  id: string; guest: string; initials: string; phone: string; roomId: string; room: string;
  arrivalDate: string; departureDate: string; arrival: string; departure: string;
  amount: string; status: "inquiry" | "confirmed" | "checked_in" | "checked_out" | "cancelled" | "no_show";
  housekeepingStatus: string;
  standardRateKobo?: number; nightlyRateKobo?: number; pricingReason?: string; complimentary?: boolean;
  nightRates?: { date: string; standardKobo: number; agreedKobo: number; rateName: string }[];
};
export type LiveFolio = { id: string; reservationId: string; status: string; items: {
  id: string; type: string; description: string; serviceDate: string; totalKobo: number;
}[] };
export type DepartmentOption = { id: string; code: string; name: string };
export type PaymentMethodOption = { id: string; name: string };
export type LiveGuest = { id: string; name: string; phone: string; email: string };
export type LiveDeposit = { id: string; folioId: string; paymentId: string; amountKobo: number;
  appliedKobo: number; refundedKobo: number };
export type LivePayment = { id: string; folioId: string; amountKobo: number; isDeposit: boolean; receivedAt: string };
export type HotelContext = {
  organizationId: string; userId: string; propertyId: string; propertyName: string; ownerName: string;
  properties: { id: string; name: string }[]; expenses: { id: string; date: string; vendor: string; description: string; amountKobo: number; receiptPath: string }[]; teamMembers: { userId: string; email: string; fullName: string; role: string; active: boolean }[];
  role: string; rooms: LiveRoom[]; stays: LiveStay[]; folios: LiveFolio[]; guests: LiveGuest[];
  deposits: LiveDeposit[]; payments: LivePayment[];
  departments: DepartmentOption[]; paymentMethods: PaymentMethodOption[];
  finance: { ready: boolean; roomRevenueKobo: number; otherRevenueKobo: number; expenseKobo: number;
    paymentsKobo: number; outstandingKobo: number; roomNights: number; monthStart: string;
    entries: { id: string; date: string; memo: string; source: string; amountKobo: number }[] };
};
const nav: { label: Screen; icon: typeof LayoutDashboard }[] = [
  { label: "Dashboard", icon: LayoutDashboard }, { label: "Reservations", icon: CalendarDays },
  { label: "Front Desk", icon: DoorOpen }, { label: "Rooms", icon: BedDouble },
  { label: "Housekeeping", icon: Sparkles }, { label: "POS", icon: ShoppingCart },
  { label: "Accounting", icon: Wallet }, { label: "Inventory", icon: Package },
  { label: "Reports", icon: BarChart3 }, { label: "Staff", icon: Users },
  { label: "Settings", icon: Settings2 },
];
const demoArrivals = [
  { guest: "Emeka Okafor", initials: "EO", room: "204 · Deluxe", stay: "Oct 4–7", balance: "₦85,000", status: "Arriving" },
  { guest: "Mariam Fashola", initials: "MF", room: "112 · Standard", stay: "Oct 2–4", balance: "₦0", status: "Departing" },
  { guest: "Jonah Akpan", initials: "JA", room: "308 · Suite", stay: "Oct 3–6", balance: "₦42,000", status: "In-house" },
];
const demoBookings = [
  { guest: "Emeka Okafor", initials: "EO", ref: "RS-2084", arrival: "Today, Oct 4", departure: "Oct 7", room: "204 · Deluxe", amount: "₦255,000", deposit: "₦170,000", status: "Arriving" },
  { guest: "Uduak King", initials: "UK", ref: "RS-2088", arrival: "Oct 5", departure: "Oct 9", room: "Unassigned · Suite", amount: "₦480,000", deposit: "₦240,000", status: "Confirmed" },
  { guest: "Theresa Nwankwo", initials: "TN", ref: "RS-2091", arrival: "Oct 6", departure: "Oct 8", room: "Unassigned · Standard", amount: "₦120,000", deposit: "₦0", status: "Deposit due" },
  { guest: "Iniobong Asuquo", initials: "IA", ref: "RS-2094", arrival: "Oct 8", departure: "Oct 11", room: "Unassigned · Deluxe", amount: "₦390,000", deposit: "₦195,000", status: "Confirmed" },
];
const dateShort = (date: string) => new Date(`${date}T12:00:00`).toLocaleDateString("en-NG", { month: "short", day: "numeric" });
const statusLabel = (status: LiveStay["status"]) => ({ inquiry: "Inquiry", confirmed: "Confirmed", checked_in: "In-house", checked_out: "Checked out", cancelled: "Cancelled", no_show: "No-show" })[status];

function downloadCsv(filename: string, headers: string[], rows: (string | number)[][]) {
  const escape = (value: string | number) => {
    const raw = String(value);
    const safe = /^[=+@-]/.test(raw) ? `'${raw}` : raw;
    return `"${safe.replaceAll('"','""')}"`;
  };
  const csv = [headers, ...rows].map(row => row.map(escape).join(",")).join("\r\n");
  const url = URL.createObjectURL(new Blob(["\uFEFF",csv],{type:"text/csv;charset=utf-8"}));
  const link = document.createElement("a");
  link.href = url; link.download = filename; link.click();
  window.setTimeout(() => URL.revokeObjectURL(url),1000);
}

export function HotelDashboard({ context, dayLabel, dateStamp }: { context?: HotelContext; dayLabel: string; dateStamp: string }) {
  const [screen, setScreen] = useState<Screen>("Dashboard");
  const [toast, setToast] = useState("");
  const [menuOpen, setMenuOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [reservationOpen, setReservationOpen] = useState(false);
  const [reservationArrival, setReservationArrival] = useState<string | undefined>(undefined);
  const [reservationRoomId, setReservationRoomId] = useState<string | undefined>(undefined);
  const [folioStayId, setFolioStayId] = useState<string | null>(null);
  const [closeStayId, setCloseStayId] = useState<string | null>(null);
  const [depositStayId, setDepositStayId] = useState<string | null>(null);
  const live = Boolean(context);
  const notify = (message: string) => { setToast(message); window.setTimeout(() => setToast(""), 2800); };
  useEffect(() => {
    const restore = () => setScreen(parseScreen(window.location.hash, context?.role));
    restore(); window.addEventListener("hashchange", restore); window.addEventListener("popstate", restore);
    return () => { window.removeEventListener("hashchange", restore); window.removeEventListener("popstate", restore); };
  }, [context?.role]);
  const [guestDirectory, setGuestDirectory] = useState(false);
  const page = (name: Screen) => { if (!canViewScreen(name, context?.role)) return; const hash = `#${screenHash(name)}`; if (window.location.hash !== hash) window.history.pushState(null, "", `${window.location.pathname}${window.location.search}${hash}`); setScreen(name); setMenuOpen(false); window.scrollTo({ top: 0, behavior: "smooth" }); };
  const propertyName = context?.propertyName ?? "Calabar Seaview Hotel";
  const ownerName = context?.ownerName ?? "Amaka Okon";
  const initials = ownerName.split(/\s+/).slice(0, 2).map(part => part[0]).join("").toUpperCase();
  const visibleBookings = context ? context.stays.filter(stay => `${stay.guest} ${stay.room} ${stay.phone}`.toLowerCase().includes(query.toLowerCase())) : demoBookings.filter(item => `${item.guest} ${item.ref} ${item.room}`.toLowerCase().includes(query.toLowerCase()));
  const openReservation = (arrivalDate?: string, roomId?: string) => { if (context) { setReservationArrival(arrivalDate); setReservationRoomId(roomId); setReservationOpen(true); } else notify("This preview uses sample data. Connect Supabase to save reservations."); };

  return <div className="app-shell">
    <aside className={`sidebar ${menuOpen ? "sidebar-open" : ""}`}>
      <div className="brand"><div className="brand-mark">C</div><div><strong>Coastline</strong><small>HOTEL OPERATIONS</small></div><button className="icon-button close-menu" onClick={() => setMenuOpen(false)} aria-label="Close menu"><X size={18}/></button></div>
      <label className="property-picker"><span className="overline">CURRENT PROPERTY</span><select aria-label="Current property" value={context?.propertyId ?? ""} onChange={event => { if (event.target.value) window.location.href = `/?property=${encodeURIComponent(event.target.value)}`; }} disabled={!context || context.properties.length < 2}>{context?.properties.map(property => <option key={property.id} value={property.id}>{property.name}</option>) ?? <option>{propertyName}</option>}</select><ChevronDown size={15}/></label>
      <div className="nav-label">WORKSPACE</div><nav className="side-nav" aria-label="Hotel navigation">{nav.filter(item => canViewScreen(item.label, context?.role)).map(({ label, icon: Icon }) => <button key={label} aria-current={screen === label ? "page" : undefined} className={screen === label ? "nav-item active" : "nav-item"} onClick={() => page(label)}><Icon size={18}/><span>{label}</span></button>)}</nav>
      <div className="sidebar-bottom"><div className="help-card"><Sparkles size={16}/><div><strong>{live ? "First hotel is connected" : "Demo workspace"}</strong><span>{live ? "Reservations save to your Supabase database." : "Connect Supabase when you’re ready to save real stays."}</span></div></div><div className="user-row"><div className="avatar">{initials}</div><div><strong>{ownerName}</strong><small>{context?.role.replaceAll("_"," ") ?? "Hotel owner"}</small></div>{live && <LogoutButton compact/>}</div></div>
    </aside>
    {menuOpen && <button className="scrim" aria-label="Close navigation" onClick={() => setMenuOpen(false)}/>}
    <main className="main-area">
      <header className="topbar"><button className="icon-button menu-button" aria-label="Open navigation" onClick={() => setMenuOpen(true)}><Menu size={19}/></button><div className="breadcrumb">{propertyName} <span>/</span><strong>{screen}</strong></div><div className="top-actions"><span className="current-date">{dayLabel}</span><button className="icon-button notification" aria-label="Notifications" onClick={() => notify("You’re all caught up.")}><Bell size={18}/><i/></button><div className="avatar">{initials}</div></div></header>
      <div className="page-content">
        {context && <StaffShiftPanel key={context.propertyId} organizationId={context.organizationId} propertyId={context.propertyId} userId={context.userId} name={context.ownerName} role={context.role}/>}
        {screen === "Dashboard" && <Overview dayLabel={dayLabel} dateStamp={dateStamp} page={page} notify={notify} context={context}/>}
        {screen === "Front Desk" && <><div className="module-tabs"><Button onClick={() => setGuestDirectory(false)} className={!guestDirectory ? "button-primary" : ""}>Today’s stays</Button><Button onClick={() => setGuestDirectory(true)} className={guestDirectory ? "button-primary" : ""}>Guest directory</Button></div>{guestDirectory ? <Guests query={query} setQuery={setQuery} notify={notify} context={context}/> : <FrontDesk dateStamp={dateStamp} notify={notify} context={context} openReservation={openReservation} openFolio={setFolioStayId} page={page}/>}</>}
        {screen === "Reservations" && <Reservations dateStamp={dateStamp} query={query} setQuery={setQuery} rows={visibleBookings} notify={notify} context={context} openReservation={openReservation} openClose={setCloseStayId} openFolio={setFolioStayId} openDeposit={setDepositStayId}/>}
        {screen === "Rooms" && <Rooms dateStamp={dateStamp} context={context} openReservation={openReservation} openFolio={setFolioStayId} page={page}/>}
        {screen === "Housekeeping" && <Housekeeping context={context}/>}
        {screen === "POS" && <POS context={context} openFolio={setFolioStayId}/>}
        {screen === "Inventory" && <InventoryPanel context={context}/>}
        {screen === "Reports" && <Reports context={context}/>}
        {screen === "Accounting" && <Finance notify={notify} context={context}/>}
        {screen === "Staff" && context && <AdminPanel organizationId={context.organizationId} propertyId={context.propertyId} propertyName={context.propertyName} properties={context.properties} members={context.teamMembers} role={context.role}/>}
        {screen === "Staff" && !context && <PageHeading eyebrow="HOTEL TEAM" title="Staff" description="Connect your hotel to invite staff and manage property access."/>}
        {screen === "Settings" && <PropertySettings context={context}/>}
        <footer className="page-footer"><span>Coastline PMS <i>·</i> {live ? "Connected workspace" : "MVP demo preview"}</span><span>Amounts shown in Nigerian naira</span></footer>
      </div>
    </main>
    {reservationOpen && context && <ReservationDialog organizationId={context.organizationId} propertyId={context.propertyId} role={context.role} initialArrival={reservationArrival} initialRoomId={reservationRoomId} onClose={() => { setReservationOpen(false); setReservationArrival(undefined); setReservationRoomId(undefined); }}/>}
    {folioStayId && context && <FolioDialog stay={context.stays.find(stay => stay.id === folioStayId)!} folio={context.folios.find(folio => folio.reservationId === folioStayId)} methods={context.paymentMethods} departments={context.departments} deposits={context.deposits} payments={context.payments} role={context.role} onClose={() => setFolioStayId(null)}/>}
    {closeStayId && context && <CloseReservationDialog stay={context.stays.find(stay => stay.id === closeStayId)!} onClose={() => setCloseStayId(null)}/>}
    {depositStayId && context && <DepositDialog stay={context.stays.find(stay => stay.id === depositStayId)!} deposits={context.deposits.filter(deposit => deposit.folioId === context.folios.find(folio => folio.reservationId === depositStayId)?.id)} methods={context.paymentMethods} role={context.role} onClose={() => setDepositStayId(null)}/>}
    {toast && <div className="toast"><Check size={16}/>{toast}</div>}
  </div>;
}

function PageHeading({ eyebrow, title, description, children }: { eyebrow: string; title: string; description: string; children?: React.ReactNode }) { return <div className="page-heading"><div><div className="eyebrow">{eyebrow}</div><h1>{title}</h1><p>{description}</p></div>{children && <div className="heading-actions">{children}</div>}</div>; }
function Button({ children, primary = false, onClick, className = "" }: { children: React.ReactNode; primary?: boolean; onClick?: () => void; className?: string }) { return <button className={`button ${primary ? "button-primary" : ""} ${className}`} onClick={onClick}>{children}</button>; }
function Metric({ label, value, foot, icon: Icon, tone = "green" }: { label: string; value: string; foot: React.ReactNode; icon: typeof Activity; tone?: string }) { return <article className="metric-card"><div className="metric-label">{label}<span className={`metric-icon ${tone}`}><Icon size={17}/></span></div><strong className="metric-value">{value}</strong><div className="metric-foot">{foot}</div></article>; }
function CardHeading({ title, note, action }: { title: string; note?: string; action?: React.ReactNode }) { return <div className="card-heading"><div><strong>{title}</strong>{note && <small>{note}</small>}</div>{action}</div>; }
function Overview({ page, notify, context, dayLabel, dateStamp }: { dayLabel: string; dateStamp: string; page: (name: Screen) => void; notify: (m: string) => void; context?: HotelContext }) {
  if (context) {
    const occupied = context.stays.filter(stay => stay.status === "checked_in").length;
    const arrivals = context.stays.filter(stay => stay.status === "confirmed" && stay.arrivalDate === dateStamp).length;
    const usable = context.rooms.filter(room => room.status !== "out_of_order" && !room.maintenanceBlocked).length;
    const occupiedRoomIds = new Set(context.stays.filter(stay => stay.status === "checked_in").map(stay => stay.roomId));
    const ready = context.rooms.filter(room => ["clean", "inspected"].includes(room.status) && !room.maintenanceBlocked && !occupiedRoomIds.has(room.id)).length;
    const upcoming = context.stays.filter(stay => stay.status === "confirmed" || stay.status === "checked_in")
      .sort((a,b) => a.arrivalDate.localeCompare(b.arrivalDate));
    return <><PageHeading eyebrow={dayLabel.toUpperCase()} title={`Welcome, ${context.ownerName.split(" ")[0]}`} description={`Here’s the live room and stay picture for ${context.propertyName}.`}><select className="select-control"><option>Today</option></select></PageHeading>
      <div className="metrics-grid">{["owner","manager","accountant"].includes(context.role) ? <><Metric label="Recognized revenue" value={context.finance.ready ? formatKobo(context.finance.roomRevenueKobo + context.finance.otherRevenueKobo) : "—"} icon={ArrowUpRight} foot="Posted income · this month"/><Metric label="Net income" value={context.finance.ready ? formatKobo(context.finance.roomRevenueKobo + context.finance.otherRevenueKobo - context.finance.expenseKobo) : "—"} icon={CircleDollarSign} foot="Recognized income less expenses"/></> : <><Metric label="Departures today" value={String(context.stays.filter(stay => stay.status === "checked_in" && stay.departureDate <= dateStamp).length)} icon={ArrowUpRight} foot="Guests due to check out"/><Metric label="Rooms ready" value={String(ready)} icon={BedDouble} foot="Clean and available"/></>}<Metric label="Occupancy today" value={usable ? `${Math.round(occupied / usable * 100)}%` : "0%"} icon={BedDouble} foot={`${occupied} in-house · ${usable} active rooms`}/><Metric label="Arrivals today" value={String(arrivals)} icon={Users} tone="amber" foot={`${ready} rooms ready to sell`}/></div>
      <div className="content-grid two-col"><article className="panel"><CardHeading title="Upcoming stays" note={`${upcoming.length} active reservations`} action={<button className="text-button" onClick={() => page("Reservations")}>View reservations <ArrowRight size={14}/></button>}/>{upcoming.length ? <LiveStayTable stays={upcoming.slice(0,6)}/> : <div className="empty-state">No active reservations yet. Add your first stay to begin.</div>}</article><article className="panel"><CardHeading title="Rooms today" note="Housekeeping status" action={<span className="status-pill green-pill">{ready} ready</span>}/><div className="occupancy"><div className="occupancy-stats"><div><span><i className="legend-dot green-dot"/>Clean or inspected</span><b>{ready} rooms</b></div><div><span><i className="legend-dot amber-dot"/>Need cleaning</span><b>{context.rooms.filter(room => (room.status === "dirty" && !room.maintenanceBlocked)).length} rooms</b></div><div><span><i className="legend-dot grey-dot"/>Out of order</span><b>{context.rooms.filter(room => (room.status === "out_of_order" || room.maintenanceBlocked)).length} rooms</b></div><div><span><i className="legend-dot pale-dot"/>Occupied</span><b>{occupied} rooms</b></div></div><div className="insight"><span><Sparkles size={15}/></span><div><strong>Accounting activity is connected</strong><p>Recognized revenue comes from posted room and extra charges. Payments are reported separately.</p></div></div></div></article></div>
      <div className="content-grid two-col lower-grid"><article className="panel"><CardHeading title="Today’s front desk" note="Confirmed arrivals and guests in-house" action={<button className="text-button" onClick={() => page("Front Desk")}>Open front desk <ArrowRight size={14}/></button>}/>{context.stays.length ? <LiveStayTable stays={context.stays.filter(stay => stay.status === "confirmed" || stay.status === "checked_in").slice(0,5)}/> : <div className="empty-state">Create a reservation to see arrivals here.</div>}</article><article className="panel"><CardHeading title="Today’s checklist" note="Keep the front desk moving"/><div className="follow-list"><Follow icon="1" title="Prepare rooms" note="Mark cleaned rooms ready" amount="Rooms"/><Follow icon="2" title="Review arrivals" note="Check guests in when rooms are ready" amount="Front Desk"/><Follow icon="3" title="Post completed nights" note="Open in-house folios to recognize revenue" amount="Folios"/></div></article></div>
    </>;
  }
  return <><PageHeading eyebrow={dayLabel.toUpperCase()} title="Good morning, Amaka" description="Here’s how Calabar Seaview Hotel is doing today."><select className="select-control"><option>This month · October</option><option>Today</option><option>Last month</option></select><Button onClick={() => notify("Report export is available after you connect your hotel data.")}><ArrowDownToLine size={15}/> Export</Button></PageHeading>
    <div className="metrics-grid"><Metric label="Recognized revenue" value="₦8.42m" icon={ArrowUpRight} foot={<><span className="positive">↑ 12.8%</span> vs September · sample</>}/><Metric label="Net income" value="₦3.16m" icon={CircleDollarSign} foot="Sample data · not your hotel books"/><Metric label="Occupancy today" value="78%" icon={BedDouble} foot="39 of 50 rooms · sample"/><Metric label="Payments collected" value="₦6.85m" icon={Wallet} tone="amber" foot="Sample data · not live payments"/></div>
    <div className="content-grid two-col"><article className="panel"><CardHeading title="Revenue and expenses" note="Sample posted activity · October" action={<button className="text-button" onClick={() => page("Accounting")}>View report <ArrowRight size={14}/></button>}/><RevenueChart/></article><article className="panel"><CardHeading title="Today at a glance" note="Sample property operations" action={<span className="status-pill green-pill">Demo</span>}/><div className="occupancy"><div className="occupancy-title"><strong>39 <small>/ 50 rooms</small></strong><span>78%</span></div><p>Occupied tonight</p><div className="progress"><i style={{ width: "78%" }}/><i style={{ width: "8%" }}/></div><div className="occupancy-stats"><div><span><i className="legend-dot green-dot"/>Occupied</span><b>39 rooms</b></div><div><span><i className="legend-dot amber-dot"/>Arriving</span><b>4 guests</b></div><div><span><i className="legend-dot grey-dot"/>Available</span><b>7 rooms</b></div><div><span><i className="legend-dot amber-dot"/>Departing</span><b>6 guests</b></div></div><div className="insight"><span><Sparkles size={15}/></span><div><strong>Demo dashboard</strong><p>Connect Supabase and complete hotel setup to save and view real stays.</p></div></div></div></article></div>
    <div className="content-grid two-col lower-grid"><article className="panel"><CardHeading title="Arrivals & departures" note="Sample stays" action={<button className="text-button" onClick={() => page("Front Desk")}>Open front desk <ArrowRight size={14}/></button>}/><GuestTable rows={demoArrivals}/></article><article className="panel"><CardHeading title="Money to follow up" note="Sample balances" action={<button className="text-button" onClick={() => page("Accounting")}>View all <ArrowRight size={14}/></button>}/><div className="follow-list"><Follow icon="◷" title="Guest folios" note="Demo balance" amount="₦420,000"/><Follow icon="⇄" title="Transfers to confirm" note="Demo references" amount="₦180,000"/><Follow icon="✓" title="Unposted expenses" note="Demo review" amount="₦65,500"/></div></article></div>
  </>;
}
function RevenueChart() { return <div className="chart-area"><svg viewBox="0 0 680 200" preserveAspectRatio="none" aria-label="Sample revenue and expenses trend"><defs><linearGradient id="area-fill" x1="0" x2="0" y1="0" y2="1"><stop offset="0" stopColor="#176b53" stopOpacity=".16"/><stop offset="1" stopColor="#176b53" stopOpacity="0"/></linearGradient></defs><g className="grid-lines"><path d="M0 30H680M0 76H680M0 122H680M0 168H680"/></g><path className="area-shape" d="M0 136 C42 130 48 98 91 108 S143 127 181 82 S227 97 271 71 S326 95 362 62 S416 75 454 46 S512 72 545 37 S606 62 638 24 S660 42 680 14 L680 178 L0 178Z"/><path className="revenue-line" d="M0 136 C42 130 48 98 91 108 S143 127 181 82 S227 97 271 71 S326 95 362 62 S416 75 454 46 S512 72 545 37 S606 62 638 24 S660 42 680 14"/><path className="expense-line" d="M0 159 C50 148 54 135 92 146 S148 156 181 132 S233 143 271 117 S323 140 362 111 S416 128 454 98 S505 115 545 93 S606 114 638 80 S665 100 680 74"/></svg><div className="chart-footer"><div className="chart-legend"><span><i className="legend-dot green-dot"/>Revenue</span><span><i className="legend-dot pale-dot"/>Expenses</span></div><div className="chart-dates"><span>Oct 1</span><span>Oct 8</span><span>Oct 15</span><span>Oct 22</span><span>Oct 31</span></div></div></div>; }
function Follow({ icon, title, note, amount }: { icon: string; title: string; note: string; amount: string }) { return <div className="follow-row"><span className="follow-icon">{icon}</span><div><strong>{title}</strong><small>{note}</small></div><b>{amount}</b></div>; }
function PageTools({ children }: { children: React.ReactNode }) { return <div className="page-tools">{children}</div>; }
function SearchBox({ value, onChange, placeholder = "Search guest, phone or code" }: { value: string; onChange: (value: string) => void; placeholder?: string }) { return <label className="search-box"><Search size={15}/><input value={value} onChange={event => onChange(event.target.value)} placeholder={placeholder}/></label>; }
function GuestName({ initials, name }: { initials: string; name: string }) { return <span className="guest-name"><i>{initials}</i>{name}</span>; }
function Pill({ label }: { label: string }) { const style = ["Deposit due", "Cancelled", "No-show", "Out of order", "Maintenance"].includes(label) ? "red-pill" : ["Arriving", "Dirty", "Inquiry", "Reserved"].includes(label) ? "amber-pill" : ["In-house", "Occupied"].includes(label) ? "blue-pill" : "green-pill"; return <span className={`status-pill ${style}`}>{label}</span>; }
function GuestTable({ rows }: { rows: typeof demoArrivals }) { return <div className="table-wrap"><table><thead><tr><th>Guest</th><th>Room</th><th>Stay</th><th>Balance</th><th>Status</th></tr></thead><tbody>{rows.map(row => <tr key={row.guest}><td><GuestName initials={row.initials} name={row.guest}/></td><td>{row.room}</td><td>{row.stay}</td><td className="tabular">{row.balance}</td><td><Pill label={row.status}/></td></tr>)}</tbody></table></div>; }
function LiveStayTable({ stays }: { stays: LiveStay[] }) { return <div className="table-wrap"><table><thead><tr><th>Guest</th><th>Room</th><th>Stay</th><th>Quoted total</th><th>Status</th></tr></thead><tbody>{stays.map(stay => <tr key={stay.id}><td><GuestName initials={stay.initials} name={stay.guest}/></td><td>{stay.room}</td><td>{dateShort(stay.arrivalDate)}–{dateShort(stay.departureDate)}</td><td className="tabular">{stay.amount}{stay.pricingReason && <small className="sub-cell">{stay.complimentary ? "Complimentary" : "Approved rate"}</small>}</td><td><Pill label={statusLabel(stay.status)}/></td></tr>)}</tbody></table></div>; }
function FrontDesk({ context, openReservation, openFolio, dateStamp, page }: { dateStamp: string; notify: (m: string) => void; context?: HotelContext; openReservation: () => void; openFolio: (id: string) => void; page: (screen: Screen) => void }) {
  const [deskQuery,setDeskQuery] = useState("");
  const [deskFilter,setDeskFilter] = useState("current");
  if (!context) return <><PageHeading eyebrow="DAILY OPERATIONS" title="Front Desk" description="Sample arrivals, departures and in-house stays for today."><Button primary onClick={() => openReservation()}><Plus size={15}/> Walk-in booking</Button></PageHeading><div className="panel empty-state">Front desk actions are available after Supabase is connected. This demo is read-only.</div><section className="panel" style={{ marginTop: 14 }}><GuestTable rows={demoArrivals}/></section></>;
  const rows = context.stays.filter(stay => stay.status === "checked_in" || (stay.status === "confirmed" && stay.arrivalDate <= dateStamp))
    .filter(stay => deskFilter === "arrivals" ? stay.status === "confirmed" : deskFilter === "in_house" ? stay.status === "checked_in" : true)
    .filter(stay => `${stay.guest} ${stay.room} ${stay.phone}`.toLowerCase().includes(deskQuery.toLowerCase())).slice(0,30);
  const arrivalsToday = context.stays.filter(stay => stay.status === "confirmed" && stay.arrivalDate === dateStamp).length;
  const occupied = context.stays.filter(stay => stay.status === "checked_in").length;
  return <><PageHeading eyebrow="DAILY OPERATIONS" title="Front Desk" description={`Arrivals, departures and in-house stays at ${context.propertyName}.`}><Button onClick={() => page("Rooms")}><BedDouble size={15}/> Room board</Button><Button primary onClick={() => openReservation()}><Plus size={15}/> Walk-in booking</Button></PageHeading><div className="metrics-grid four"><Metric label="Arrivals today" value={String(arrivalsToday)} icon={ArrowDownUp} foot="Confirmed stays arriving today"/><Metric label="Departures today" value={String(context.stays.filter(stay => stay.status === "checked_in" && stay.departureDate === dateStamp).length)} icon={ArrowUpRight} foot="In-house stays due out"/><Metric label="In-house stays" value={String(occupied)} icon={Users} foot="Guests currently checked in"/><Metric label="Rooms to prepare" value={String(context.rooms.filter(room => (room.status === "dirty" && !room.maintenanceBlocked)).length)} icon={ClipboardList} tone="amber" foot="Marked dirty by housekeeping"/></div><section className="panel"><div className="page-tools"><SearchBox value={deskQuery} onChange={setDeskQuery}/><select className="select-control" value={deskFilter} onChange={event => setDeskFilter(event.target.value)}><option value="current">Current stays</option><option value="arrivals">Arrivals</option><option value="in_house">In-house</option></select><Button onClick={() => downloadCsv("front-desk.csv",["Guest","Room","Arrival","Departure","Status"],rows.map(stay => [stay.guest,stay.room,stay.arrivalDate,stay.departureDate,statusLabel(stay.status)]))}><ArrowDownToLine size={15}/> Export</Button></div><div className="table-wrap"><table><thead><tr><th>Guest / reservation</th><th>Room</th><th>Stay dates</th><th>Quoted total</th><th>Status</th><th>Next action</th></tr></thead><tbody>{rows.map(stay => <tr key={stay.id}><td><GuestName initials={stay.initials} name={stay.guest}/><small className="sub-cell">{stay.phone || "Direct booking"}</small></td><td>{stay.room}</td><td>{dateShort(stay.arrivalDate)}–{dateShort(stay.departureDate)}</td><td className="tabular">{stay.amount}{stay.pricingReason && <small className="sub-cell">{stay.complimentary ? "Complimentary" : "Approved rate"}</small>}</td><td><Pill label={statusLabel(stay.status)}/></td><td>{stay.status === "confirmed" ? <CheckInAction reservationId={stay.id}/> : <Button onClick={() => openFolio(stay.id)}>Open folio</Button>}</td></tr>)}</tbody></table>{!rows.length && <div className="empty-state">No confirmed or in-house stays yet.</div>}</div></section><CashierControls propertyId={context.propertyId} role={context.role}/></>;
}
function Reservations({ query, setQuery, rows, notify, context, openReservation, openClose, openFolio, openDeposit, dateStamp }: { dateStamp: string; query: string; setQuery: (v: string) => void; rows: LiveStay[] | typeof demoBookings; notify: (m: string) => void; context?: HotelContext; openReservation: () => void; openClose: (id: string) => void; openFolio: (id: string) => void; openDeposit: (id: string) => void }) {
  const [statusFilter,setStatusFilter] = useState("all");
  const [dateFilter,setDateFilter] = useState("all");
  const [calendarOpen,setCalendarOpen] = useState(false);
  const sevenDays = new Date(new Date(`${dateStamp}T00:00:00Z`).getTime()+7*86400000).toISOString().slice(0,10);
  const displayRows = context ? (rows as LiveStay[]).filter(stay => statusFilter === "all" || stay.status === statusFilter)
    .filter(stay => dateFilter === "week" ? stay.arrivalDate >= dateStamp && stay.arrivalDate <= sevenDays :
      dateFilter === "month" ? stay.arrivalDate.slice(0,7) === dateStamp.slice(0,7) : true) : rows;
  return <><PageHeading eyebrow="STAY MANAGEMENT" title="Reservations" description={context ? `Reservations for ${context.propertyName}.` : "Sample reservations · demo data only."}><Button onClick={() => setCalendarOpen(value => !value)}><CalendarDays size={15}/>{calendarOpen ? "Reservation list" : "Availability calendar"}</Button><Button primary onClick={() => openReservation()}><Plus size={15}/> New reservation</Button></PageHeading>
    {!context && <div className="demo-notice">These bookings are examples. Connect Supabase to create saved reservations.</div>}
    {calendarOpen && context && <AvailabilityCalendar rooms={context.rooms} stays={context.stays} propertyName={context.propertyName} onCreate={openReservation}/>}
    {calendarOpen && !context && <section className="panel empty-state">The availability calendar appears when a hotel database is connected.</section>}
    {!calendarOpen && <section className="panel"><PageTools><SearchBox value={query} onChange={setQuery}/><select className="select-control" value={statusFilter} onChange={event => setStatusFilter(event.target.value)}><option value="all">All statuses</option><option value="confirmed">Confirmed</option><option value="checked_in">Checked in</option><option value="checked_out">Checked out</option><option value="cancelled">Cancelled</option><option value="no_show">No-show</option></select><select className="select-control" value={dateFilter} onChange={event => setDateFilter(event.target.value)}><option value="all">All dates</option><option value="week">Next 7 days</option><option value="month">This month</option></select><Button onClick={() => context ? downloadCsv("reservations.csv",["Guest","Reservation","Arrival","Departure","Room","Quoted total","Status"],(displayRows as LiveStay[]).map(stay => [stay.guest,stay.id,stay.arrivalDate,stay.departureDate,stay.room,stay.amount,statusLabel(stay.status)])) : notify("Connect Supabase to export saved reservations.")}><ArrowDownToLine size={15}/> Export</Button></PageTools><div className="table-wrap"><table><thead><tr><th>Guest</th><th>Confirmation</th><th>Arrival</th><th>Departure</th><th>Room / type</th><th>Quoted amount</th><th>Status</th><th>Action</th></tr></thead><tbody>{context ? (displayRows as LiveStay[]).map(stay => <tr key={stay.id}><td><GuestName initials={stay.initials} name={stay.guest}/></td><td>{stay.id.slice(0,8).toUpperCase()}</td><td>{dateShort(stay.arrivalDate)}</td><td>{dateShort(stay.departureDate)}</td><td>{stay.room}</td><td className="tabular">{stay.amount}{stay.pricingReason && <small className="sub-cell">{stay.complimentary ? "Complimentary" : "Approved rate"}</small>}</td><td><Pill label={statusLabel(stay.status)}/></td><td>{stay.status === "confirmed" && ["owner","manager","front_desk"].includes(context.role) && <><button className="text-button" onClick={() => openDeposit(stay.id)}>Deposit</button><button className="text-button" onClick={() => openClose(stay.id)}>Cancel / no-show</button></>}{stay.status === "checked_in" && <EarlyCheckoutAction reservationId={stay.id}/>}{["checked_in","checked_out"].includes(stay.status) && <button className="text-button" onClick={() => openFolio(stay.id)}>View folio</button>}</td></tr>) : (displayRows as typeof demoBookings).map(row => <tr key={row.ref}><td><GuestName initials={row.initials} name={row.guest}/></td><td>{row.ref}</td><td>{row.arrival}</td><td>{row.departure}</td><td>{row.room}</td><td className="tabular">{row.amount}</td><td><Pill label={row.status}/></td><td>—</td></tr>)}</tbody></table>{displayRows.length === 0 && <div className="empty-state">No reservations match that search.</div>}</div><div className="table-pagination"><span>Showing {displayRows.length} reservation{displayRows.length === 1 ? "" : "s"}</span><span><b>1</b></span></div></section>}</>;
}
function Rooms({ context, dateStamp, openReservation, openFolio, page }: { context?: HotelContext; dateStamp: string; openReservation: (date?: string, room?: string) => void; openFolio: (id: string) => void; page: (screen: Screen) => void }) {
  const [filter, setFilter] = useState<RoomState | "All">("All");
  const [search, setSearch] = useState("");
  const states: RoomState[] = ["Available", "Occupied", "Reserved", "Dirty", "Maintenance"];
  const rooms = context?.rooms ?? [];
  const stays = context?.stays ?? [];
  const visible = rooms.filter(room => (filter === "All" || roomState(room, stays, dateStamp) === filter) && `${room.number} ${room.type}`.toLowerCase().includes(search.toLowerCase()));
  return <><PageHeading eyebrow="LIVE ROOM INVENTORY" title="Rooms" description="See what is happening in each physical room today. Future availability is in Reservations.">{(!context || ["owner", "manager"].includes(context.role)) && <Button onClick={() => page("Settings")}>Configure rooms</Button>}</PageHeading>
    <div className="module-tabs"><Button className={filter === "All" ? "button-primary" : ""} onClick={() => setFilter("All")}>All · {rooms.length}</Button>{states.map(state => <Button key={state} className={filter === state ? "button-primary" : ""} onClick={() => setFilter(state)}>{state} · {rooms.filter(room => roomState(room, stays, dateStamp) === state).length}</Button>)}</div>
    <SearchBox value={search} onChange={setSearch} placeholder="Search room number or type"/>
    <div className="live-room-grid">{visible.map(room => {
      const state = roomState(room, stays, dateStamp);
      const stay = stays.find(stay => stay.roomId === room.id && (stay.status === "checked_in" || (stay.status === "confirmed" && stay.arrivalDate <= dateStamp && stay.departureDate > dateStamp)));
      return <article className="room-card" key={room.id}><strong>Room {room.number}</strong><span>{room.type} · {formatKobo(room.rateKobo)}/night base</span><Pill label={state}/>{state === "Occupied" && room.maintenanceBlocked && <small className="form-error">Maintenance issue · review room block</small>}<span>{stay?.guest ?? (state === "Dirty" ? "Waiting for cleaning" : state === "Maintenance" ? "Blocked from sale" : "Ready for a guest")}</span>{context && ["owner","manager","front_desk"].includes(context.role) && (state === "Available" ? <Button onClick={() => openReservation(dateStamp, room.id)}>Book room</Button> : stay ? <Button onClick={() => state === "Occupied" ? openFolio(stay.id) : page("Reservations")}>{state === "Occupied" ? "View stay / folio" : "View reservation"}</Button> : null)}{state === "Dirty" && canViewScreen("Housekeeping", context?.role) && <Button onClick={() => page("Housekeeping")}>Open housekeeping</Button>}{state === "Occupied" && stay && context && ["owner","manager","front_desk"].includes(context.role) && <RoomMoveControl reservationId={stay.id} rooms={rooms.filter(target => target.id !== room.id && roomState(target, stays, dateStamp) === "Available").map(target => ({ id: target.id, number: target.number }))}/>}</article>;
    })}</div>{!visible.length && <section className="panel empty-state">{context ? "No rooms match this view. Administrators can add physical rooms in Settings." : "Connect your hotel to see live room inventory."}</section>}
    {context && <MaintenancePanel organizationId={context.organizationId} propertyId={context.propertyId} rooms={context.rooms} role={context.role}/>}</>;
}
function Housekeeping({ context }: { context?: HotelContext }) {
  const [filter, setFilter] = useState("dirty");
  const occupied = new Set(context?.stays.filter(stay => stay.status === "checked_in").map(stay => stay.roomId));
  const rooms = context?.rooms.filter(room => filter === "all" || room.status === filter) ?? [];
  return <><PageHeading eyebrow="ROOM READINESS" title="Housekeeping" description="Clean and inspect rooms independently of guest occupancy. Staff assignment is planned for a later increment."/><div className="module-tabs">{["dirty","clean","inspected","out_of_order","all"].map(status => <Button key={status} className={status === filter ? "button-primary" : ""} onClick={() => setFilter(status)}>{status.replaceAll("_"," ")}</Button>)}</div><section className="panel"><div className="table-wrap"><table><thead><tr><th>Room</th><th>Type</th><th>Guest occupancy</th><th>Cleaning status</th><th>Action</th></tr></thead><tbody>{rooms.map(room => <tr key={room.id}><td>{room.number}</td><td>{room.type}</td><td>{occupied.has(room.id) ? "Occupied" : "Vacant"}</td><td>{room.status.replaceAll("_"," ")}{room.maintenanceBlocked && " · Maintenance block"}</td><td><RoomStatusAction roomId={room.id} status={room.status}/></td></tr>)}</tbody></table>{!rooms.length && <p className="empty-state">{context ? "No rooms in this cleaning queue." : "Connect your hotel to manage cleaning."}</p>}</div></section></>;
}
function POS({ context, openFolio }: { context?: HotelContext; openFolio: (id: string) => void }) {
  const stays = context?.stays.filter(stay => stay.status === "checked_in") ?? [];
  return <><PageHeading eyebrow="HOTEL SALES" title="POS" description="Charge meals, drinks, laundry and services to an in-house guest’s folio."/><section className="panel"><CardHeading title="Charge to room" note="Open a folio and add a charge with its department. Catalog tickets and standalone cash sales are planned for the next POS increment."/><div className="table-wrap"><table><thead><tr><th>Guest</th><th>Room</th><th>Action</th></tr></thead><tbody>{stays.map(stay => <tr key={stay.id}><td>{stay.guest}</td><td>{stay.room}</td><td><Button onClick={() => openFolio(stay.id)}>Add charge / take payment</Button></td></tr>)}</tbody></table>{!stays.length && <p className="empty-state">{context ? "Check in a guest to charge services to their room." : "Connect your hotel to post sales."}</p>}</div></section>{context && <CashierControls propertyId={context.propertyId} role={context.role}/>}</>;
}
function Reports({ context }: { context?: HotelContext }) {
  return <><PageHeading eyebrow="HOTEL PERFORMANCE" title="Reports" description="Historical financial statements, guest balances, exports and reconciliation."/>{context?.finance.ready ? <FinancialReports propertyId={context.propertyId} methods={context.paymentMethods} from={context.finance.monthStart} role={context.role}/> : <section className="panel empty-state">{context ? "Financial reports are unavailable. Ask the administrator to check the hotel database update." : "Connect your hotel to view posted financial reports."}</section>}</>;
}
function Finance({ notify, context }: { notify: (m: string) => void; context?: HotelContext }) {
  if (context) {
    const finance = context.finance;
    if (!finance.ready) return <><PageHeading eyebrow="OWNER VIEW" title="Accounting" description="The finance database migration is ready to install."/><section className="panel finance-placeholder"><CircleDollarSign size={28}/><strong>Apply the finance migration</strong><p>Run supabase/migrations/20261004000200_finance_workflows.sql in your Supabase SQL Editor, then refresh this page.</p></section></>;
    const revenue = finance.roomRevenueKobo + finance.otherRevenueKobo;
    return <><PageHeading eyebrow="OWNER VIEW" title="Accounting" description={`Posted ledger activity at ${context.propertyName} from ${finance.monthStart} to today.`}/>
      <div className="metrics-grid"><Metric label="Room revenue" value={formatKobo(finance.roomRevenueKobo)} icon={BedDouble} foot="Completed room nights"/><Metric label="Other revenue" value={formatKobo(finance.otherRevenueKobo)} icon={Plus} foot="Posted guest extras"/><Metric label="Operating expenses" value={formatKobo(finance.expenseKobo)} icon={ArrowUpRight} tone="amber" foot="Recognized costs this month"/><Metric label="Net income" value={formatKobo(revenue-finance.expenseKobo)} icon={CircleDollarSign} foot="Revenue less expenses"/></div>
      <div className="metrics-grid two-finance-metrics"><Metric label="Guest payments collected" value={formatKobo(finance.paymentsKobo)} icon={Wallet} foot="Cash, bank and POS this month"/><Metric label="Open folio balance" value={formatKobo(finance.outstandingKobo)} icon={ClipboardList} foot="Unsettled posted charges across open stays"/></div>
      <div className="content-grid two-col"><section className="panel"><CardHeading title="Recent posted journals" note="Debits equal credits for every entry"/><div className="table-wrap"><table><thead><tr><th>Date</th><th>Source</th><th>Description</th><th>Amount</th></tr></thead><tbody>{finance.entries.map(entry => <tr key={entry.id}><td>{entry.date}</td><td>{entry.source.replaceAll("_"," ")}</td><td>{entry.memo}</td><td className="tabular">{formatKobo(entry.amountKobo)}</td></tr>)}</tbody></table>{!finance.entries.length && <div className="empty-state">No ledger entries this month yet.</div>}</div></section><section className="panel"><CardHeading title="Post a paid expense" note="Records an expense and the cash, bank or POS movement"/><div className="finance-form-wrap"><ExpenseForm propertyId={context.propertyId} methods={context.paymentMethods} departments={context.departments}/></div></section></div>
      <ExpenseList expenses={context.expenses}/>
      <SupplierAccountsPanel key={context.propertyId} propertyId={context.propertyId} role={context.role} methods={context.paymentMethods} departments={context.departments}/>
      <p className="finance-note">Figures use the property’s accounting date. Reservation quotes are excluded until a charge posts. Paid expenses record payment immediately; supplier invoices record an amount owed until settled.</p>
    </>;
  }
  return <><PageHeading eyebrow="OWNER VIEW · SAMPLE DATA" title="Accounting" description="Illustrative values only · not connected to a hotel ledger."><select className="select-control"><option>October sample period</option></select><Button onClick={() => notify("Connect a hotel ledger before exporting reports.")}><ArrowDownToLine size={15}/> Export report</Button></PageHeading><div className="metrics-grid four"><Metric label="Room revenue" value="₦7.18m" icon={BedDouble} foot="Example figure"/><Metric label="Other revenue" value="₦1.24m" icon={Plus} foot="Example figure"/><Metric label="Operating expenses" value="₦5.26m" icon={ArrowUpRight} tone="amber" foot="Example figure"/><Metric label="Net income" value="₦3.16m" icon={CircleDollarSign} foot="Example figure"/></div><section className="panel finance-placeholder"><CircleDollarSign size={28}/><strong>Sample finance view</strong><p>Real profit and revenue reports will appear after folio and expense events are linked to the accounting ledger.</p></section></>;
}
function Guests({ query, setQuery, notify, context }: { query: string; setQuery: (v: string) => void; notify: (m: string) => void; context?: HotelContext }) {
  if (context) {
    const people = context.guests.filter(guest => `${guest.name} ${guest.phone} ${guest.email}`.toLowerCase().includes(query.toLowerCase()));
    return <><PageHeading eyebrow="GUEST DIRECTORY" title="Guests" description={`Guest profiles saved by ${context.propertyName}’s organization.`}><Button primary onClick={() => notify("Create a reservation to add a guest profile.")}><Plus size={15}/> Add through booking</Button></PageHeading>
      <section className="panel"><PageTools><SearchBox value={query} onChange={setQuery} placeholder="Search name, phone or email"/></PageTools>
        <div className="table-wrap"><table><thead><tr><th>Guest</th><th>Phone</th><th>Email</th></tr></thead><tbody>{people.map(guest => <tr key={guest.id}><td><GuestName initials={guest.name.split(/\s+/).slice(0,2).map(part => part[0] ?? "").join("").toUpperCase()} name={guest.name}/></td><td>{guest.phone || "—"}</td><td>{guest.email || "—"}</td></tr>)}</tbody></table>{!people.length && <div className="empty-state">No guests match this search.</div>}</div></section></>;
  }
  const demoPeople = [{ name: "Emeka Okafor", initials: "EO", phone: "+234 803 ••• 1182", email: "emeka@example.com" }, { name: "Mariam Fashola", initials: "MF", phone: "+234 809 ••• 4421", email: "mariam@example.com" }].filter(person => `${person.name} ${person.phone}`.toLowerCase().includes(query.toLowerCase()));
  return <><PageHeading eyebrow="GUEST DIRECTORY · SAMPLE DATA" title="Guests" description="Guest profiles in the demo workspace."/><section className="panel"><PageTools><SearchBox value={query} onChange={setQuery} placeholder="Search name, phone or email"/></PageTools><div className="table-wrap"><table><thead><tr><th>Guest</th><th>Phone</th><th>Email</th></tr></thead><tbody>{demoPeople.map(person => <tr key={person.name}><td><GuestName initials={person.initials} name={person.name}/></td><td>{person.phone}</td><td>{person.email}</td></tr>)}</tbody></table></div></section></>;
}
function formatKobo(value: number) { return `₦${new Intl.NumberFormat("en-NG").format(Math.round(value / 100))}`; }
