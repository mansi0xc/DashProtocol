"use client"

import { useState, useRef, useEffect } from "react"
import { Send, Mic } from "lucide-react"
import { Button } from "@/components/ui/button"

interface Message {
  id: string
  type: "user" | "ai"
  content: string
}

export default function ChatPanel() {
  const [messages, setMessages] = useState<Message[]>([
    {
      id: "1",
      type: "ai",
      content:
        "Welcome to Dash Protocol! I'm your AI DeFi orchestrator. You can ask me to swap tokens, stake assets, or manage your portfolio across multiple chains.",
    },
  ])
  const [input, setInput] = useState("")
  const [isListening, setIsListening] = useState(false)
  const messagesEndRef = useRef<HTMLDivElement>(null)

  const scrollToBottom = () => {
    messagesEndRef.current?.scrollIntoView({ behavior: "smooth" })
  }

  useEffect(() => {
    scrollToBottom()
  }, [messages])

  const handleSend = () => {
    if (!input.trim()) return

    const userMessage: Message = {
      id: Date.now().toString(),
      type: "user",
      content: input,
    }

    setMessages((prev: Message[]) => [...prev, userMessage])

    // Simulate AI response
    setTimeout(() => {
      const aiMessage: Message = {
        id: (Date.now() + 1).toString(),
        type: "ai",
        content: "I'll help you with that. Processing your request...",
      }
      setMessages((prev: Message[]) => [...prev, aiMessage])
    }, 500)

    setInput("")
  }

  const handleVoiceTranscript = (text: string) => {
    setInput(text)
    // Auto-send after voice input
    setTimeout(() => {
      const userMessage: Message = {
        id: Date.now().toString(),
        type: "user",
        content: text,
      }
      setMessages((prev: Message[]) => [...prev, userMessage])

      setTimeout(() => {
        const aiMessage: Message = {
          id: (Date.now() + 1).toString(),
          type: "ai",
          content: "I'll help you with that. Processing your request...",
        }
        setMessages((prev: Message[]) => [...prev, aiMessage])
      }, 500)

      setInput("")
    }, 300)
  }


  return (
    <>
      <div className="flex-1 flex flex-col bg-black">
        {/* Header */}
        <div className="px-6 py-8 border-b border-white/10 mt-20">
          <div className="flex flex-col space-y-3">
            <div className="flex flex-col space-y-1">
              <h1 className="text-3xl font-bold bg-linear-to-r from-cyan-400 to-purple-400 bg-clip-text text-transparent">
                Dash Protocol
              </h1>
              <p className="text-lg text-white/80 font-medium">AI DeFi Orchestrator</p>
            </div>
            <div className="flex items-center space-x-2 text-sm text-white/60">
              <div className="w-2 h-2 rounded-full bg-green-400 animate-pulse"></div>
              <span>Ready to assist with your DeFi operations</span>
            </div>
          </div>
        </div>

        {/* Messages */}
        <div className="flex-1 overflow-y-auto px-6 py-4 space-y-4">
          {messages.map((message: Message) => (
            <div key={message.id} className={`flex ${message.type === "user" ? "justify-end" : "justify-start"}`}>
              <div
                className={`max-w-xs lg:max-w-md px-4 py-3 rounded-lg transition-all ${
                  message.type === "user"
                    ? "bg-linear-to-r from-cyan-500/20 to-purple-500/20 border border-cyan-500/50 text-white shadow-lg shadow-cyan-500/10"
                    : "bg-white/10 backdrop-blur-md border border-white/20 text-white"
                }`}
              >
                <p className="text-sm leading-relaxed">{message.content}</p>
              </div>
            </div>
          ))}
          <div ref={messagesEndRef} />
        </div>

        {/* Input Area */}
        <div className="px-6 py-4">
          <div className="flex gap-3">
            <button
              onClick={() => setIsListening(!isListening)}
              className={`p-3 rounded-lg transition-all shrink-0 ${
                isListening
                  ? "bg-linear-to-r from-cyan-500 to-purple-500 text-white shadow-lg shadow-cyan-500/50 glow-pulse"
                  : "bg-white/10 backdrop-blur-md text-white/70 hover:text-white hover:bg-white/20 border border-white/20"
              }`}
            >
              <Mic size={20} />
            </button>
            <input
              type="text"
              value={input}
              onChange={(e) => setInput(e.target.value)}
              onKeyPress={(e) => e.key === "Enter" && handleSend()}
              placeholder="Ask Dash..."
              className="flex-1 px-4 py-3 rounded-lg bg-white/10 backdrop-blur-md border border-white/20 text-white placeholder-white/50 focus:outline-none focus:border-cyan-500 focus:ring-2 focus:ring-cyan-500/20 transition-all"
            />
            <Button
              onClick={handleSend}
              className="px-4 py-3 bg-linear-to-r from-cyan-500 to-purple-500 text-white hover:shadow-lg hover:shadow-cyan-500/50 transition-all shrink-0"
            >
              <Send size={20} />
            </Button>
          </div>
        </div>
      </div>

    </>
  )
}
