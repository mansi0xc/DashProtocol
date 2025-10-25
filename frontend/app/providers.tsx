"use client";

import "@rainbow-me/rainbowkit/styles.css";
import { RainbowKitProvider, getDefaultWallets } from "@rainbow-me/rainbowkit";
import { WagmiProvider, createConfig, http } from "wagmi";
import { 
  sepolia, 
  mainnet, 
  baseSepolia, 
  polygonAmoy,
  polygon,
  arbitrum,
  optimism,
  base,
  avalanche,
  bsc
} from "wagmi/chains";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { ReactNode, useState, useEffect } from "react";

const { wallets } = getDefaultWallets({
  appName: "Dash Protocol",
  projectId: "a0e61a5ad2605042ba79131bfd73c66c",
});

const chains = [
  mainnet,
  polygon,
  arbitrum,
  optimism,
  base,
  avalanche,
  bsc,
  sepolia,
  baseSepolia,
  polygonAmoy
] as const;

const config = createConfig({
  chains,
  transports: {
    [mainnet.id]: http(),
    [polygon.id]: http(),
    [arbitrum.id]: http(),
    [optimism.id]: http(),
    [base.id]: http(),
    [avalanche.id]: http(),
    [bsc.id]: http(),
    [sepolia.id]: http(),
    [baseSepolia.id]: http(),
    [polygonAmoy.id]: http(),
  },
});

const queryClient = new QueryClient();

export default function Providers({ children }: { children: ReactNode }) {
  const [mounted, setMounted] = useState(false);

  useEffect(() => {
    setMounted(true);
  }, []);

  if (!mounted) {
    return <>{children}</>;
  }

  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>
        <RainbowKitProvider>
          {children}
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}