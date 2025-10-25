"use client"

import { useState } from "react"
import { Menu, X } from "lucide-react"
import { Button } from "@/components/ui/button"
import CustomConnectButton from "./custom-connect-button"


interface NavbarProps {
  currentPage?: string
  onNavigate?: (page: string) => void
  onLogout?: () => void
}

export default function Navbar({ currentPage = "home", onNavigate, onLogout }: NavbarProps) {
  const [mobileMenuOpen, setMobileMenuOpen] = useState(false)

  const navigation = [
    { id: "home", label: "Home" },
    { id: "dashboard", label: "Dashboard" },
    { id: "settings", label: "Settings" },
  ]

  const handleNavigation = (pageId: string) => {
    onNavigate?.(pageId)
    setMobileMenuOpen(false)
  }

  return (
    <nav className="fixed top-4 left-1/2 transform -translate-x-1/2 z-50 w-auto max-w-4xl mx-4 rounded-2xl border border-white/20 bg-white/10 backdrop-blur-md supports-backdrop-filter:bg-white/5 shadow-lg">
      <div className="px-6 py-3">
        <div className="flex items-center justify-between gap-4">
          {/* Logo */}
          <div className="flex items-center">
            <span className="text-xl font-bold text-white">DashProtocol</span>
          </div>

          {/* Desktop Navigation */}
          <div className="hidden md:flex items-center space-x-1">
            {navigation.map((item) => (
              <Button
                key={item.id}
                variant={currentPage === item.id ? "default" : "ghost"}
                onClick={() => handleNavigation(item.id)}
                className={`px-4 py-2 rounded-lg font-semibold transition-all ${
                  currentPage === item.id
                    ? "bg-linear-to-r from-cyan-500 to-purple-500 text-white"
                    : "text-white/80 hover:text-white hover:bg-white/10"
                }`}
              >
                {item.label}
              </Button>
            ))}
          </div>

          {/* Right side actions */}
          <div className="flex items-center space-x-2">
            {/* Connect Button */}
            <CustomConnectButton />

            {/* Mobile menu button */}
            <Button
              variant="ghost"
              size="sm"
              className="md:hidden text-white/80 hover:text-white hover:bg-white/10"
              onClick={() => setMobileMenuOpen(!mobileMenuOpen)}
            >
              {mobileMenuOpen ? <X size={20} /> : <Menu size={20} />}
            </Button>
          </div>
        </div>

        {/* Mobile Navigation */}
        {mobileMenuOpen && (
          <div className="md:hidden mt-3">
            <div className="px-2 pt-2 pb-3 space-y-1 border-t border-white/20">
              {navigation.map((item) => (
                <Button
                  key={item.id}
                  variant={currentPage === item.id ? "default" : "ghost"}
                  onClick={() => handleNavigation(item.id)}
                  className={`w-full justify-start px-4 py-3 rounded-lg font-semibold transition-all ${
                    currentPage === item.id
                      ? "bg-linear-to-r from-cyan-500 to-purple-500 text-white"
                      : "text-white/80 hover:text-white hover:bg-white/10"
                  }`}
                >
                  {item.label}
                </Button>
              ))}
              <div className="px-4 py-3">
                <CustomConnectButton />
              </div>
              {onLogout && (
                <Button
                  variant="ghost"
                  onClick={onLogout}
                  className="w-full justify-start px-4 py-3 text-white/80 hover:text-white hover:bg-white/10 font-semibold"
                >
                  Logout
                </Button>
              )}
            </div>
          </div>
        )}
      </div>
    </nav>
  )
}
