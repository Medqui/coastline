import type { Metadata } from "next";
import localFont from "next/font/local";
import "./globals.css";

const dashboardFont = localFont({
  src: "./fonts/geist-latin.woff2",
  variable: "--font-dashboard",
  weight: "100 900",
  display: "swap",
});

export const metadata: Metadata = {
  title: "Coastline PMS | Calabar Hotel Operations",
  description: "Hotel operations and owner finance dashboard for Calabar hotels.",
  icons: {
    icon: "/icon.svg",
    shortcut: "/icon.svg",
    apple: "/icon.svg",
  },
};

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en" className={dashboardFont.variable}><body>{children}</body></html>;
}
