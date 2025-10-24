"use client"

import { useState } from "react"
import { Menu, X } from "lucide-react"
import Sidebar from "@/components/sidebar"
import ChatPanel from "@/components/chat-panel"
import InsightPanel from "@/components/insight-panel"

export default function DashboardLayout() {
  const [sidebarOpen, setSidebarOpen] = useState(true)
  const [mobileMenuOpen, setMobileMenuOpen] = useState(false)

  return (
    <div className="h-screen bg-black flex">
      {/* Mobile Menu Button */}
      <button
        onClick={() => setMobileMenuOpen(!mobileMenuOpen)}
        className="fixed top-6 left-6 z-40 p-3 rounded-xl bg-white/10 backdrop-blur-md border border-white/20 hover:bg-white/20 transition-all lg:hidden shadow-lg"
      >
        {mobileMenuOpen ? <X size={20} className="text-white" /> : <Menu size={20} className="text-white" />}
      </button>

      {/* Sidebar - Hidden on mobile unless menu is open */}
      <div
        className={`fixed lg:relative z-30 h-full transition-all duration-300 ${
          mobileMenuOpen ? "translate-x-0" : "-translate-x-full lg:translate-x-0"
        }`}
        style={{ overflow: 'visible' }}
      >
        <Sidebar isOpen={sidebarOpen} onToggle={() => setSidebarOpen(!sidebarOpen)} />
      </div>

      {/* Mobile Overlay */}
      {mobileMenuOpen && (
        <div className="fixed inset-0 bg-black/50 z-20 lg:hidden" onClick={() => setMobileMenuOpen(false)}></div>
      )}

      {/* Main Content */}
      <div className="flex-1 flex flex-col lg:flex-row overflow-hidden">
        {/* Chat Panel */}
        <ChatPanel />

        {/* Insight Panel - Hidden on mobile, visible on lg+ */}
        <div className="hidden lg:flex">
          <InsightPanel />
        </div>
      </div>
    </div>
  )
}
