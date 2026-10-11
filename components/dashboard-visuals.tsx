"use client";

import { useId } from "react";

export type OccupancyPoint = { date: string; occupied: number; booked: number };
export type RoomTypeCount = { name: string; count: number };
const shortDate = (date: string) => new Date(`${date}T12:00:00Z`).toLocaleDateString("en-NG", { day: "numeric", month: "short", timeZone: "Africa/Lagos" });

export function OccupancyTrend({ points, note }: { points: OccupancyPoint[]; note: string }) {
  const gradientId = useId();
  const x = (index: number) => points.length === 1 ? 336 : 52 + index / (points.length - 1) * 568;
  const y = (value: number) => 202 - Math.min(100, Math.max(0, value)) * 1.7;
  const path = (key: "occupied" | "booked") => points.map((point, index) => `${index ? "L" : "M"}${x(index)},${y(point[key])}`).join(" ");
  const tickIndices = [...new Set(Array.from({ length: Math.min(5, points.length) }, (_, index) => Math.round(index * (points.length - 1) / Math.max(1, Math.min(5, points.length) - 1))))];
  return <section className="panel occupancy-trend-panel">
    <div className="card-heading"><div><strong>Room occupancy trend</strong><small>{note}</small></div></div>
    <div className="dashboard-chart-legend"><span><i className="legend-dot"/>Occupied</span><span><i className="legend-dot amber-dot"/>Booked incl. occupied</span></div>
    {points.length ? <div className="occupancy-trend-chart"><svg viewBox="0 0 650 245" role="img" aria-label={`Daily occupied and booked room percentages, ${shortDate(points[0].date)} to ${shortDate(points[points.length - 1].date)}`}>
      <defs><linearGradient id={gradientId} x1="0" y1="0" x2="0" y2="1"><stop offset="0" stopColor="#176b53" stopOpacity=".16"/><stop offset="1" stopColor="#176b53" stopOpacity=".01"/></linearGradient></defs>
      {[0, 25, 50, 75, 100].map(value => <g key={value}><line x1="52" x2="620" y1={y(value)} y2={y(value)} stroke="#e9eeeb" strokeDasharray="4 5"/><text x="40" y={y(value) + 4} textAnchor="end">{value}%</text></g>)}
      {points.length > 1 && <path d={`${path("occupied")} L620,202 L52,202 Z`} fill={`url(#${gradientId})`}/>}
      <path d={path("booked")} fill="none" stroke="#d6a43d" strokeWidth="2.5" strokeDasharray="5 5"/>
      <path d={path("occupied")} fill="none" stroke="#176b53" strokeWidth="3" strokeLinejoin="round"/>
      {points.length === 1 && <><circle cx={x(0)} cy={y(points[0].booked)} r="5" fill="#d6a43d"/><circle cx={x(0)} cy={y(points[0].occupied)} r="5" fill="#176b53"/></>}
      {tickIndices.map(index => <text key={index} x={x(index)} y="231" textAnchor="middle">{shortDate(points[index].date)}</text>)}
    </svg></div> : <p className="empty-state">No occupancy figures for this period.</p>}
    <details className="chart-data-details"><summary>View daily figures</summary><div className="table-wrap"><table><thead><tr><th>Date</th><th>Occupied</th><th>Booked incl. occupied</th></tr></thead><tbody>{points.map(point => <tr key={point.date}><td>{shortDate(point.date)}</td><td>{point.occupied.toFixed(1)}%</td><td>{point.booked.toFixed(1)}%</td></tr>)}</tbody></table></div></details>
  </section>;
}

const roomColors = ["#176b53", "#8abb83", "#e5bc56", "#6c91ac", "#a593b8", "#c88f75"];
export function RoomDistribution({ rooms }: { rooms: RoomTypeCount[] }) {
  const total = rooms.reduce((sum, room) => sum + room.count, 0);
  let cumulative = 0;
  const stops = rooms.map((room, index) => {
    const start = cumulative;
    cumulative += room.count / total * 100;
    return `${roomColors[index % roomColors.length]} ${start}% ${cumulative}%`;
  });
  return <section className="panel room-distribution-panel"><div className="card-heading"><div><strong>Room distribution</strong><small>Active rooms by type</small></div></div>
    {total ? <><div className="room-distribution-ring" style={{ background: `conic-gradient(${stops.join(",")})` }} role="img" aria-label={`${total} rooms: ${rooms.map(room => `${room.count} ${room.name}`).join(", ")}`}><div><span>Total rooms</span><strong>{total}</strong></div></div><div className="room-distribution-legend">{rooms.map((room, index) => <div key={room.name}><span><i style={{ background: roomColors[index % roomColors.length] }}/>{room.name}</span><b>{room.count}</b></div>)}</div></> : <p className="empty-state">Add rooms to see your room distribution.</p>}
  </section>;
}
