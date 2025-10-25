"use client"

import { LineChart, Line, ResponsiveContainer, Tooltip } from "recharts"

interface MiniChartProps {
  data: Array<{ name: string; value: number }>
  color: string
  height?: number
}

export default function MiniChart({ data, color, height = 60 }: MiniChartProps) {
  return (
    <ResponsiveContainer width="100%" height={height}>
      <LineChart data={data}>
        <Tooltip
          contentStyle={{
            backgroundColor: "rgba(15, 23, 42, 0.9)",
            border: "1px solid rgba(100, 116, 139, 0.5)",
            borderRadius: "8px",
          }}
          labelStyle={{ color: "#e2e8f0" }}
        />
        <Line type="monotone" dataKey="value" stroke={color} dot={false} strokeWidth={2} isAnimationActive={false} />
      </LineChart>
    </ResponsiveContainer>
  )
}
