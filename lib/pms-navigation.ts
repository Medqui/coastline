export const screens = ["Dashboard", "Reservations", "Front Desk", "Rooms", "Housekeeping", "POS", "Accounting", "Inventory", "Reports", "Staff", "Settings"] as const;
export type Screen = typeof screens[number];
const access: Record<string, readonly Screen[]> = {
  owner: screens,
  manager: screens,
  front_desk: ["Dashboard", "Reservations", "Front Desk", "Rooms", "Housekeeping", "POS"],
  housekeeping: ["Dashboard", "Rooms", "Housekeeping"],
  accountant: ["Dashboard", "Rooms", "Accounting", "Inventory", "Reports"],
};
export function canViewScreen(screen: Screen, role?: string) {
  return role === undefined || (access[role]?.includes(screen) ?? false);
}
export function screenHash(screen: Screen) { return screen.toLowerCase().replaceAll(" ", "-"); }
export function parseScreen(hash: string, role?: string): Screen {
  return screens.find(screen => screenHash(screen) === hash.replace(/^#/, "") && canViewScreen(screen, role)) ?? "Dashboard";
}
export type RoomState = "Available" | "Occupied" | "Reserved" | "Dirty" | "Maintenance";
export function roomState(room: { id: string; status: string; maintenanceBlocked?: boolean }, stays: { roomId: string; status: string; arrivalDate: string; departureDate: string }[], date: string): RoomState {
  if (stays.some(stay => stay.roomId === room.id && stay.status === "checked_in")) return "Occupied";
  if (room.status === "out_of_order" || room.maintenanceBlocked) return "Maintenance";
  if (room.status === "dirty") return "Dirty";
  if (stays.some(stay => stay.roomId === room.id && stay.status === "confirmed" && stay.arrivalDate <= date && stay.departureDate > date)) return "Reserved";
  return "Available";
}
