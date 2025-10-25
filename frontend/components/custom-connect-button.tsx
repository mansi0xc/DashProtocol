"use client"

import { ConnectButton } from '@rainbow-me/rainbowkit'
import { Button } from '@/components/ui/button'
import { useState, useEffect } from 'react'

export default function CustomConnectButton() {
  const [mounted, setMounted] = useState(false)

  useEffect(() => {
    setMounted(true)
  }, [])

  if (!mounted) {
    return (
      <Button className="px-4 py-2 rounded-lg font-semibold transition-all bg-white/10 text-white/90 border border-white/20">
        Connect Wallet
      </Button>
    )
  }
  return (
    <ConnectButton.Custom>
      {({
        account,
        chain,
        openAccountModal,
        openChainModal,
        openConnectModal,
        authenticationStatus,
        mounted,
      }) => {
        // Note: If your app doesn't use authentication, you
        // can remove all 'authenticationStatus' checks
        const ready = mounted && authenticationStatus !== 'loading'
        const connected =
          ready &&
          account &&
          chain &&
          (!authenticationStatus ||
            authenticationStatus === 'authenticated')

        return (
          <div
            {...(!ready && {
              'aria-hidden': true,
              'style': {
                opacity: 0,
                pointerEvents: 'none',
                userSelect: 'none',
              },
            })}
          >
            {(() => {
              if (!connected) {
                return (
                  <Button
                    onClick={openConnectModal}
                    className="px-4 py-2 rounded-lg font-semibold transition-all bg-linear-to-r from-cyan-500 to-purple-500 text-white hover:shadow-lg hover:shadow-cyan-500/50 border border-cyan-500/50"
                  >
                    Connect Wallet
                  </Button>
                )
              }

              if (chain.unsupported) {
                return (
                  <Button
                    onClick={openChainModal}
                    className="px-4 py-2 rounded-lg font-semibold transition-all bg-orange-500/20 text-orange-400 hover:bg-orange-500/30 border border-orange-500/50"
                  >
                    Switch Network
                  </Button>
                )
              }

              return (
                <div className="flex items-center gap-2">
                  <Button
                    onClick={openChainModal}
                    className="px-3 py-2 rounded-lg font-medium transition-all bg-white/10 text-white/90 hover:bg-white/20 border border-white/20"
                  >
                    {chain.hasIcon && (
                      <div className="w-4 h-4 mr-2">
                        {chain.iconUrl && (
                          <img
                            alt={chain.name ?? 'Chain icon'}
                            src={chain.iconUrl}
                            className="w-4 h-4"
                          />
                        )}
                      </div>
                    )}
                    {chain.name}
                  </Button>

                  <Button
                    onClick={openAccountModal}
                    className="px-4 py-2 rounded-lg font-semibold transition-all bg-white/10 text-white/90 hover:bg-white/20 border border-white/20"
                  >
                    {account.displayName}
                    {account.displayBalance
                      ? ` (${account.displayBalance})`
                      : ''}
                  </Button>
                </div>
              )
            })()}
          </div>
        )
      }}
    </ConnectButton.Custom>
  )
}
