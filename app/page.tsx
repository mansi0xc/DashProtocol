"use client"

import { useState } from "react"
import Navbar from "@/components/navbar"
import HeroSection from "@/components/hero-section"
import DashboardLayout from "@/components/dashboard-layout"
import Orb from '@/components/Orb';

export default function Home() {
  const [currentPage, setCurrentPage] = useState("home")

  const handleNavigation = (page: string) => {
    setCurrentPage(page)
  }

  const handleLogout = () => {
    setCurrentPage("home")
  }

  const renderPage = () => {
    switch (currentPage) {
      case "dashboard":
        return <DashboardLayout />
      case "settings":
        return (
          <div className="container mx-auto px-4 py-8">
            <h1 className="text-3xl font-bold mb-6">Settings</h1>
            <p className="text-muted-foreground">Settings page coming soon...</p>
          </div>
        )
      default:
        return <HeroSection onDemoClick={() => setCurrentPage("dashboard")} />
    }
  }

  return (
    <div className="min-h-screen bg-background">
      <Navbar 
        currentPage={currentPage}
        onNavigate={handleNavigation}
        onLogout={handleLogout}
      />
      <main className="flex-1">
        {renderPage()}
      </main>
    </div>
  )
}
