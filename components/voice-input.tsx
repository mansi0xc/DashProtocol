"use client"

import { useState, useEffect } from "react"
import { Mic, Square } from "lucide-react"

interface VoiceInputProps {
  onTranscript: (text: string) => void
  isListening: boolean
  onListeningChange: (listening: boolean) => void
}

export default function VoiceInput({ onTranscript, isListening, onListeningChange }: VoiceInputProps) {
  const [transcript, setTranscript] = useState("")
  const [waveformBars, setWaveformBars] = useState<number[]>(Array(12).fill(20))

  useEffect(() => {
    if (!isListening) return

    // Simulate waveform animation
    const interval = setInterval(() => {
      setWaveformBars((prev) => prev.map(() => Math.random() * 80 + 20))
    }, 100)

    return () => clearInterval(interval)
  }, [isListening])

  const handleToggle = () => {
    onListeningChange(!isListening)
    if (isListening && transcript) {
      onTranscript(transcript)
      setTranscript("")
    }
  }

  return (
    <div className="flex flex-col items-center gap-4">
      {/* Voice Button */}
      <button
        onClick={handleToggle}
        className={`relative p-6 rounded-full transition-all duration-300 ${
          isListening
            ? "bg-gradient-to-r from-cyan-500 to-purple-500 text-white shadow-2xl shadow-cyan-500/50 glow-pulse"
            : "bg-slate-800 text-gray-400 hover:text-gray-200 hover:bg-slate-700 border border-slate-700"
        }`}
      >
        {isListening ? <Square size={32} /> : <Mic size={32} />}
        {isListening && (
          <div className="absolute inset-0 rounded-full bg-gradient-to-r from-cyan-500 to-purple-500 opacity-20 animate-pulse"></div>
        )}
      </button>

      {/* Waveform Animation */}
      {isListening && (
        <div className="flex items-center justify-center gap-1 h-16">
          {waveformBars.map((height, i) => (
            <div
              key={i}
              className="w-1.5 bg-gradient-to-t from-cyan-500 to-purple-500 rounded-full transition-all duration-100"
              style={{ height: `${height}%` }}
            ></div>
          ))}
        </div>
      )}

      {/* Transcript Display */}
      {transcript && (
        <div className="max-w-md p-4 rounded-lg bg-slate-800/50 border border-slate-700/50">
          <p className="text-sm text-gray-300">
            <span className="text-gray-500">Listening: </span>
            {transcript}
          </p>
        </div>
      )}

      {/* Status Text */}
      <p className="text-sm text-gray-400">
        {isListening ? "Listening... Click to stop" : "Click to start voice input"}
      </p>
    </div>
  )
}
