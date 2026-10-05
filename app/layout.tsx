import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "Coastline PMS | Calabar Hotel Operations",
  description: "Hotel operations and owner finance dashboard for Calabar hotels.",
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body>{children}</body></html>;
}
