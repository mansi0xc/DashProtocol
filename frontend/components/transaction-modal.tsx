"use client"

import { X, CheckCircle2, AlertCircle } from "lucide-react"
import { Button } from "@/components/ui/button"

interface TransactionModalProps {
  isOpen: boolean
  onClose: () => void
  onConfirm: () => void
  title: string
  details: string
  status?: "pending" | "success" | "error"
}

export default function TransactionModal({
  isOpen,
  onClose,
  onConfirm,
  title,
  details,
  status = "pending",
}: TransactionModalProps) {
  if (!isOpen) return null

  return (
    <div className="fixed inset-0 bg-black/50 backdrop-blur-sm z-50 flex items-center justify-center p-4">
      <div className="bg-slate-900 border border-slate-700 rounded-xl max-w-md w-full p-6 shadow-2xl shadow-cyan-500/20">
        {/* Header */}
        <div className="flex items-center justify-between mb-4">
          <h3 className="text-lg font-semibold text-white">{title}</h3>
          <button onClick={onClose} className="p-1 hover:bg-slate-800 rounded-lg transition-colors">
            <X size={20} className="text-gray-400" />
          </button>
        </div>

        {/* Status Icon */}
        <div className="flex justify-center mb-4">
          {status === "pending" && (
            <div className="w-12 h-12 rounded-full bg-gradient-to-r from-cyan-500/20 to-purple-500/20 border border-cyan-500/50 flex items-center justify-center animate-pulse">
              <div className="w-6 h-6 rounded-full border-2 border-cyan-500 border-t-purple-500 animate-spin"></div>
            </div>
          )}
          {status === "success" && (
            <div className="w-12 h-12 rounded-full bg-green-500/20 border border-green-500/50 flex items-center justify-center">
              <CheckCircle2 size={24} className="text-green-400" />
            </div>
          )}
          {status === "error" && (
            <div className="w-12 h-12 rounded-full bg-red-500/20 border border-red-500/50 flex items-center justify-center">
              <AlertCircle size={24} className="text-red-400" />
            </div>
          )}
        </div>

        {/* Details */}
        <div className="mb-6 p-4 rounded-lg bg-slate-800/50 border border-slate-700/50">
          <p className="text-sm text-gray-300">{details}</p>
        </div>

        {/* Actions */}
        <div className="flex gap-3">
          <Button
            onClick={onClose}
            variant="outline"
            className="flex-1 border-slate-700 text-gray-300 hover:bg-slate-800 bg-transparent"
          >
            Cancel
          </Button>
          {status === "pending" && (
            <Button onClick={onConfirm} className="flex-1 bg-gradient-to-r from-cyan-500 to-purple-500 text-white">
              Confirm
            </Button>
          )}
          {status === "success" && (
            <Button onClick={onClose} className="flex-1 bg-green-600 text-white hover:bg-green-700">
              Done
            </Button>
          )}
          {status === "error" && (
            <Button onClick={onClose} className="flex-1 bg-red-600 text-white hover:bg-red-700">
              Retry
            </Button>
          )}
        </div>
      </div>
    </div>
  )
}
