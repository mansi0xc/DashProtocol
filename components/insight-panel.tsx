"use client"

import { TrendingUp, Zap, AlertCircle } from "lucide-react"
import MiniChart from "@/components/mini-chart"

export default function InsightPanel() {
  // Sample data for charts
  const ethData = [
    { name: "1h", value: 2400 },
    { name: "2h", value: 2410 },
    { name: "3h", value: 2290 },
    { name: "4h", value: 2000 },
    { name: "5h", value: 2181 },
    { name: "6h", value: 2500 },
    { name: "7h", value: 2100 },
  ]

  const btcData = [
    { name: "1h", value: 42000 },
    { name: "2h", value: 41800 },
    { name: "3h", value: 41900 },
    { name: "4h", value: 42100 },
    { name: "5h", value: 42300 },
    { name: "6h", value: 42200 },
    { name: "7h", value: 42100 },
  ]

  const portfolioData = [
    { name: "1d", value: 11800 },
    { name: "2d", value: 11900 },
    { name: "3d", value: 12100 },
    { name: "4d", value: 12200 },
    { name: "5d", value: 12350 },
    { name: "6d", value: 12400 },
    { name: "7d", value: 12450 },
  ]

  return (
    <div className="w-80 bg-black overflow-y-auto flex flex-col">
      {/* Header */}
      <div className="sticky top-0 px-6 py-4 z-10">
        <h3 className="text-lg font-semibold text-white">Portfolio Insights</h3>
      </div>

      {/* Content */}
      <div className="flex-1 p-4 space-y-4 overflow-y-auto min-h-0">
        {/* Portfolio Overview */}
        <div className="p-4 rounded-lg bg-white/10 backdrop-blur-md border border-white/20 hover:border-cyan-500/30 transition-all hover:shadow-lg hover:shadow-cyan-500/10 group cursor-pointer">
          <div className="flex items-center justify-between mb-3">
            <h4 className="text-sm font-semibold text-white group-hover:text-cyan-400 transition-colors">
              Portfolio Value
            </h4>
            <TrendingUp size={16} className="text-green-400" />
          </div>
          <p className="text-2xl font-bold text-transparent bg-clip-text bg-linear-to-r from-cyan-400 to-purple-400">
            $12,450.50
          </p>
          <p className="text-xs text-green-400 mt-2">+5.2% today</p>
          <div className="mt-3">
            <MiniChart data={portfolioData} color="#00ffff" height={40} />
          </div>
        </div>

        {/* Active Strategies */}
        <div className="p-4 rounded-lg bg-white/10 backdrop-blur-md border border-white/20 hover:border-cyan-500/30 transition-all hover:shadow-lg hover:shadow-cyan-500/10 group">
          <div className="flex items-center justify-between mb-3">
            <h4 className="text-sm font-semibold text-white group-hover:text-cyan-400 transition-colors">
              Active Strategies
            </h4>
            <Zap size={16} className="text-yellow-400" />
          </div>
          <div className="space-y-3">
            {[
              { name: "Aave Lending", apy: "8.5%", value: "$5,000" },
              { name: "Lido Staking", apy: "3.2%", value: "$4,200" },
              { name: "Curve LP", apy: "12.1%", value: "$3,250" },
            ].map((strategy, i) => (
              <div
                key={i}
                className="flex items-center justify-between text-xs p-2 rounded bg-white/10 backdrop-blur-md hover:bg-white/20 transition-colors"
              >
                <span className="text-white/80">{strategy.name}</span>
                <div className="text-right">
                  <p className="text-cyan-400 font-semibold">{strategy.apy}</p>
                  <p className="text-white/60">{strategy.value}</p>
                </div>
              </div>
            ))}
          </div>
        </div>

        {/* Market Watch - ETH */}
        <div className="p-4 rounded-lg bg-white/10 backdrop-blur-md border border-white/20 hover:border-cyan-500/30 transition-all hover:shadow-lg hover:shadow-cyan-500/10 group">
          <div className="flex items-center justify-between mb-3">
            <div>
              <h4 className="text-sm font-semibold text-white group-hover:text-cyan-400 transition-colors">ETH</h4>
              <p className="text-xs text-white/60">Ethereum</p>
            </div>
            <div className="text-right">
              <p className="text-white font-semibold">$2,450</p>
              <p className="text-xs text-green-400">+3.2%</p>
            </div>
          </div>
          <MiniChart data={ethData} color="#00ffff" height={40} />
        </div>

        {/* Market Watch - BTC */}
        <div className="p-4 rounded-lg bg-white/10 backdrop-blur-md border border-white/20 hover:border-cyan-500/30 transition-all hover:shadow-lg hover:shadow-cyan-500/10 group">
          <div className="flex items-center justify-between mb-3">
            <div>
              <h4 className="text-sm font-semibold text-white group-hover:text-cyan-400 transition-colors">BTC</h4>
              <p className="text-xs text-white/60">Bitcoin</p>
            </div>
            <div className="text-right">
              <p className="text-white font-semibold">$42,100</p>
              <p className="text-xs text-green-400">+1.8%</p>
            </div>
          </div>
          <MiniChart data={btcData} color="#9d4edd" height={40} />
        </div>

        {/* Alerts */}
        <div className="p-4 rounded-lg bg-white/10 backdrop-blur-md border border-white/20 hover:border-cyan-500/30 transition-all hover:shadow-lg hover:shadow-cyan-500/10 group">
          <div className="flex items-center justify-between mb-3">
            <h4 className="text-sm font-semibold text-white group-hover:text-cyan-400 transition-colors">Alerts</h4>
            <AlertCircle size={16} className="text-orange-400" />
          </div>
          <div className="space-y-2 text-xs">
            {["Gas prices are low - good time to swap", "Portfolio up 3% today", "New yield opportunity on Curve"].map(
              (alert, i) => (
                <p key={i} className="text-white/80 p-2 rounded bg-white/10 backdrop-blur-md">
                  {alert}
                </p>
              ),
            )}
          </div>
        </div>

        {/* Gas Price Indicator */}
        <div className="p-4 rounded-lg bg-linear-to-r from-cyan-500/10 to-purple-500/10 border border-cyan-500/30 hover:border-cyan-500/50 transition-all group cursor-pointer">
          <p className="text-xs text-white/60 mb-2">Current Gas Price</p>
          <p className="text-xl font-bold text-cyan-400 group-hover:text-cyan-300 transition-colors">42 Gwei</p>
          <p className="text-xs text-green-400 mt-1">Low - Good time to transact</p>
        </div>
      </div>
    </div>
  )
}
