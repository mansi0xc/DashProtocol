"use client"

import { useState } from "react"
import { Home, Briefcase, Bot, Bell, Settings, ChevronLeft, ChevronRight } from "lucide-react"
import { cn } from "@/lib/utils"

interface SidebarProps {
  isOpen: boolean
  onToggle: () => void
}

const navItems = [
  { icon: Home, label: "Home", id: "home" },
  { icon: Briefcase, label: "Portfolio", id: "portfolio" },
  { icon: Bot, label: "Agents", id: "agents" },
  { icon: Bell, label: "Notifications", id: "notifications" },
  { icon: Settings, label: "Settings", id: "settings" },
]

export default function Sidebar({ isOpen, onToggle }: SidebarProps) {
  const [activeItem, setActiveItem] = useState("home")

  return (
    <div
      className={cn(
        "relative transition-all duration-300 flex flex-col h-full",
        isOpen ? "w-64" : "w-20",
      )}
      style={{ overflow: 'visible' }}
    >
      {/* Toggle Button */}
      <button
        onClick={onToggle}
        className="absolute -right-3 top-8 z-60 p-2 rounded-full bg-white/10 backdrop-blur-md border border-white/20 hover:bg-white/20 transition-colors shadow-lg"
      >
        {isOpen ? <ChevronLeft size={18} className="text-white" /> : <ChevronRight size={18} className="text-white" />}
      </button>

      {/* Logo */}
      <div className={cn("p-6", !isOpen && "pr-8")}>
        <div className="flex items-center justify-center w-10 h-10 rounded-lg bg-linear-to-br from-cyan-500 to-purple-500 p-0.5">
          <div className="w-full h-full rounded-md bg-black flex items-center justify-center">
            <span className="text-lg font-bold text-transparent bg-clip-text bg-linear-to-r from-cyan-400 to-purple-400">
              D
            </span>
          </div>
        </div>
      </div>

      {/* Navigation */}
      <nav className={cn(
        "flex-1 space-y-2",
        isOpen ? "p-4 overflow-y-auto" : "p-2"
      )}>
        {navItems.map((item) => {
          const Icon = item.icon
          const isActive = activeItem === item.id
          return (
            <button
              key={item.id}
              onClick={() => setActiveItem(item.id)}
              className={cn(
                "w-full flex items-center rounded-lg transition-all duration-200 group",
                isOpen ? "gap-3 px-4 py-3" : "justify-center px-2 py-3",
                isActive
                  ? "bg-linear-to-r from-cyan-500/20 to-purple-500/20 border border-cyan-500/50 text-cyan-400 shadow-lg shadow-cyan-500/10"
                  : "text-white/70 hover:text-white hover:bg-white/10",
              )}
            >
              <Icon size={20} className="shrink-0" />
              {isOpen && <span className="text-sm font-medium">{item.label}</span>}
            </button>
          )
        })}
      </nav>

      {/* Bottom Section */}
      <div className={cn(
        isOpen ? "p-4" : "p-2"
      )}>
        <div className={cn(
          "flex items-center rounded-lg bg-white/10 backdrop-blur-md border border-white/20 hover:border-cyan-500/30 transition-colors",
          isOpen ? "gap-3 px-4 py-3" : "justify-center px-2 py-3"
        )}>
          <div className="w-8 h-8 rounded-full bg-linear-to-br from-cyan-500 to-purple-500 shrink-0"></div>
          {isOpen && (
            <div className="min-w-0">
              <p className="text-sm font-medium text-white truncate">User</p>
              <p className="text-xs text-white/60 truncate">0x1234...5678</p>
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
