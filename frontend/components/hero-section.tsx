"use client";

import { useState } from "react";
import { Mic, Send } from "lucide-react";
import { Button } from "@/components/ui/button";
import Orb from "./Orb";
import BlurText from "./BlurText";

interface HeroSectionProps {
  onDemoClick: () => void;
}

export default function HeroSection({ onDemoClick }: HeroSectionProps) {
  const [textInput, setTextInput] = useState("");
  const [isListening, setIsListening] = useState(false);

  return (
    <div className="relative h-screen overflow-hidden bg-black">
      {/* Centered Orb */}
      <div className="absolute inset-0 flex items-center justify-center">
        <div style={{ width: "100%", height: "600px", position: "relative" }}>
          <Orb
            hoverIntensity={0.5}
            rotateOnHover={true}
            hue={0}
            forceHoverState={false}
          />
        </div>
      </div>

      {/* Content */}
      <div className="relative z-10 flex flex-col items-center justify-center h-full px-4 sm:px-6 lg:px-8 py-12 pt-20">
        {/* Logo/Brand */}
        <div className="mb-6 sm:mb-8 text-center">
          <h1 className="text-4xl sm:text-5xl md:text-6xl lg:text-7xl xl:text-8xl font-semibold text-white mb-1 sm:mb-2 text-balance leading-tight tracking-tight mt-10">
            DashProtocol
          </h1>
          <h2 >
            <BlurText
              text="Let AI Orchestrate Your DeFi Journey."
              delay={150}
              animateBy="words"
              direction="top"
              className="text-2xl sm:text-3xl md:text-4xl lg:text-5xl font-medium text-white/90 mb-3 sm:mb-4 text-balance leading-tight"
            />
          </h2>
          <p className="text-base sm:text-lg md:text-xl text-white/80 max-w-2xl mx-auto text-balance font-normal leading-relaxed">
            Swap, stake, or yield across chains — just by asking in your
            language.
          </p>
        </div>

        {/* Input Section */}
        <div className="w-full max-w-2xl mb-4 sm:mb-6 px-4 sm:px-0">
          <div className="flex flex-col sm:flex-row gap-3 sm:gap-4 mb-3 sm:mb-4">
            {/* Voice Input */}
            <button
              onClick={() => setIsListening(!isListening)}
              className={`flex-1 relative group px-6 py-4 rounded-xl font-semibold transition-all duration-300 text-sm backdrop-blur-md border min-h-[56px] ${
                isListening
                  ? "bg-linear-to-r from-cyan-500 to-purple-500 text-white shadow-lg shadow-cyan-500/50 border-cyan-500/50"
                  : "bg-white/10 text-white/90 hover:bg-white/20 border-white/20 hover:border-white/30"
              }`}
            >
              <div className="flex items-center justify-center gap-2 h-full">
                <Mic size={18} className="sm:w-5 sm:h-5 shrink-0" />
                <span className="hidden sm:inline whitespace-nowrap">
                  {isListening ? "Listening..." : "Voice Input"}
                </span>
                <span className="sm:hidden whitespace-nowrap">
                  {isListening ? "Listening..." : "Voice"}
                </span>
              </div>
              {isListening && (
                <div className="absolute inset-0 rounded-lg sm:rounded-xl bg-linear-to-r from-cyan-500 to-purple-500 opacity-20 animate-pulse"></div>
              )}
            </button>

            {/* Text Input */}
            <div className="flex-1 relative">
              <input
                type="text"
                value={textInput}
                onChange={(e) => setTextInput(e.target.value)}
                placeholder="e.g. Buy $50 of ETH"
                className="w-full px-6 py-4 rounded-xl bg-white/10 backdrop-blur-md border border-white/20 text-white placeholder-white/50 text-sm focus:outline-none focus:border-cyan-500/50 focus:ring-2 focus:ring-cyan-500/20 transition-all hover:bg-white/15 font-semibold min-h-[56px]"
              />
              <button className="absolute right-2 sm:right-3 top-1/2 -translate-y-1/2 p-2 hover:bg-white/20 rounded-lg transition-colors">
                <Send size={16} className="sm:w-5 sm:h-5 text-cyan-400" />
              </button>
            </div>
          </div>

          {/* Waveform Animation - Always reserve space */}
          <div className="flex items-center justify-center gap-1 mb-3 sm:mb-4 h-8 sm:h-10">
            {isListening && (
              <>
                {[...Array(12)].map((_, i) => (
                  <div
                    key={i}
                    className="w-0.5 sm:w-1 bg-linear-to-t from-cyan-500 to-purple-500 rounded-full waveform-bar"
                    style={{ animationDelay: `${i * 0.05}s` }}
                  ></div>
                ))}
              </>
            )}
          </div>
        </div>

        {/* Try Demo Button */}
        <Button
          onClick={onDemoClick}
          className="px-8 py-4 bg-linear-to-r from-cyan-500 to-purple-500 text-white font-semibold rounded-xl hover:shadow-lg hover:shadow-cyan-500/50 transition-all text-sm backdrop-blur-md border border-cyan-500/50"
        >
          Try Demo
        </Button>
      </div>
    </div>
  );
}
