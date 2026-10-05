"use client";
import { useMemo, useState } from "react";
import { ArrowLeft, ArrowRight, CalendarDays } from "lucide-react";
import type { LiveRoom, LiveStay } from "@/components/hotel-dashboard";

const localToday = () => new Date().toLocaleDateString("en-CA", { timeZone: "Africa/Lagos" });
const shiftDate = (date: string, amount: number) => {
  const shifted = new Date(`${date}T00:00:00Z`);
  shifted.setUTCDate(shifted.getUTCDate() + amount);
  return shifted.toISOString().slice(0, 10);
};
const labelDate = (date: string) => new Date(`${date}T12:00:00`).toLocaleDateString("en-NG", { weekday: "short", day: "numeric", month: "short" });

export function AvailabilityCalendar({ rooms, stays, propertyName, onCreate }: {
  rooms: LiveRoom[]; stays: LiveStay[]; propertyName: string; onCreate: (arrivalDate: string, roomId: string) => void;
}) {
  const [startDate, setStartDate] = useState(localToday);
  const [nights, setNights] = useState(14);
  const dates = useMemo(() => Array.from({ length: nights }, (_, index) => shiftDate(startDate, index)), [startDate, nights]);
  const activeStays = stays.filter(stay => ["inquiry", "confirmed", "checked_in"].includes(stay.status));
  const availableOnStart = rooms.filter(room => room.status !== "out_of_order" && !room.maintenanceBlocked && !activeStays.some(stay => stay.roomId === room.id && stay.arrivalDate <= startDate && stay.departureDate > startDate)).length;
  return <section className="panel availability-panel">
    <div className="availability-toolbar">
      <div><strong>Room availability</strong><small>{propertyName} · each column is one night</small></div>
      <div className="availability-controls">
        <button className="button" aria-label="Previous dates" onClick={() => setStartDate(value => shiftDate(value, -nights))}><ArrowLeft size={14}/></button>
        <label className="calendar-start-date"><CalendarDays size={14}/><input aria-label="Calendar start date" type="date" value={startDate} onChange={event => event.target.value && setStartDate(event.target.value)}/></label>
        <button className="button" aria-label="Next dates" onClick={() => setStartDate(value => shiftDate(value, nights))}><ArrowRight size={14}/></button>
        <select className="select-control" aria-label="Calendar range" value={nights} onChange={event => setNights(Number(event.target.value))}><option value={7}>7 nights</option><option value={14}>14 nights</option><option value={30}>30 nights</option></select>
      </div>
    </div>
    <div className="availability-summary"><span><i className="calendar-dot available-dot"/>Available</span><span><i className="calendar-dot booked-dot"/>Reserved</span><span><i className="calendar-dot occupied-dot"/>In house</span><span><i className="calendar-dot blocked-dot"/>Blocked</span><strong>{availableOnStart} rooms free on {labelDate(startDate)}</strong></div>
    <div className="availability-scroll"><div className="availability-grid" style={{ "--night-count": nights } as React.CSSProperties}>
      <div className="availability-room-heading">Room</div>
      {dates.map((date,index) => <div className={`availability-date ${date === localToday() ? "today-column" : ""}`} key={date}><strong>{index===0?labelDate(date):labelDate(date).split(" ")[1]}</strong><small>{index===0?date.slice(0,4):new Date(`${date}T12:00:00`).toLocaleDateString("en-NG",{weekday:"short"})}</small></div>)}
      {rooms.map(room => <CalendarRoom key={room.id} room={room} dates={dates} stays={activeStays} onCreate={onCreate}/>) }
      {!rooms.length && <div className="availability-empty">No rooms are configured for this property.</div>}
    </div></div>
    <p className="availability-help">Select an available night to start a booking. The room and date availability is checked again when you save.</p>
  </section>;
}
function CalendarRoom({ room, dates, stays, onCreate }: { room: LiveRoom; dates: string[]; stays: LiveStay[]; onCreate: (date: string, roomId: string) => void }) {
  return <>
    <div className="availability-room"><strong>{room.number}</strong><small>{room.type}</small></div>
    {dates.map(date => {
      const stay = stays.find(item => item.roomId === room.id && item.arrivalDate <= date && item.departureDate > date);
      const blocked = room.status === "out_of_order" || room.maintenanceBlocked;
      if (stay) return <div key={`${room.id}-${date}`} className={`availability-cell ${stay.status === "checked_in" ? "cell-occupied" : "cell-booked"}`} title={`${stay.guest} · ${stay.arrivalDate} to ${stay.departureDate}`}><strong>{stay.guest}</strong><small>{stay.status === "checked_in" ? "In house" : room.maintenanceBlocked ? "Reserved · maintenance" : "Reserved"}</small></div>;
      if (blocked) return <div key={`${room.id}-${date}`} className="availability-cell cell-blocked"><small>{room.maintenanceBlocked ? "Maintenance" : "Out of order"}</small></div>;
      return <button key={`${room.id}-${date}`} className="availability-cell cell-available" onClick={() => onCreate(date, room.id)} aria-label={`Book room ${room.number} arriving ${date}`}><span>Available</span><small>Book</small></button>;
    })}
  </>;
}
