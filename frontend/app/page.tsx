'use client'
// import Image from "next/image";
import { useAccount, useSendTransaction, useWriteContract } from 'wagmi'
import { Button } from "@/components/ui/button"
import {
  Card,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select"
import { ConnectButton } from '@rainbow-me/rainbowkit';
import {
  baseSepolia,
  sepolia,
} from 'wagmi/chains';
import { useState } from 'react'
import { StrategyPieChart } from '@/components/pie-chart'

const chainIdToHookContractAddress = {
  [baseSepolia.id]: '0x696907c68D922c289582dA6c35E4c49E3df44800',
  [sepolia.id]: '0x92A1Fd49D8A7e6ecf3414754257bBF7652750800',
}

const strategyOptions = {
  1: {
    'baseSepolia': 40,
    'sepolia': 60,
  }
}

export default function Home() {
  const { chainId } = useAccount();
  const { data: hash, writeContract } = useWriteContract()
  const [strategy, setStrategy] = useState<number>(1);

  const handleStringToInt = (value: string) => {
    setStrategy(parseInt(value))
  }
  
  async function submit(e: React.FormEvent<HTMLFormElement>) { 
    e.preventDefault() 
    const formData = new FormData(e.target as HTMLFormElement) 
    const to = formData.get('address') as `0x${string}` 
    const value = formData.get('value') as string 
    writeContract({ to, value: parseEther(value) })
  }
  
  return (
    <div className="grid grid-rows-[20px_1fr_20px] items-center justify-items-center min-h-screen p-8 pb-20 gap-16 sm:p-20 font-[family-name:var(--font-geist-sans)]">
      <main className="flex flex-col gap-8 row-start-2 items-center sm:items-start">
      <ConnectButton />
      <Card className="w-[640px]">
      <CardHeader>
        <CardTitle>Add liquidity to a UniswapV4 pool on Base Sepolia and Ethereum Sepolia</CardTitle>
        <CardDescription>Cross-chain liquidity provision in a single interaction.</CardDescription>
      </CardHeader>
      <CardContent>
            <StrategyPieChart />
        <form>
          <div className="grid w-full items-center gap-4 mt-4">
            <div className="flex flex-col space-y-1.5">
              <Label htmlFor="contract-address">Contract Address</Label>
              <Input id="contract-address" placeholder="0x..." disabled value={chainId ? chainIdToHookContractAddress[chainId] : chainIdToHookContractAddress[baseSepolia.id]}/>
            </div>
            <div className="flex flex-col space-y-1.5">
              <Label htmlFor="strategy">Strategy</Label>
              <Select onValueChange={handleStringToInt}>
                <SelectTrigger id="framework">
                  <SelectValue placeholder="1" />
                </SelectTrigger>
                <SelectContent position="popper">
                  <SelectItem value="1">1</SelectItem>
                </SelectContent>
              </Select>
            </div>
            <div className="flex flex-col space-y-1.5">
              <Label htmlFor="tickLower">Tick Lower</Label>
              <Input id="tickLower" placeholder="0" />
            </div>
            <div className="flex flex-col space-y-1.5">
              <Label htmlFor="tickUpper">Tick Upper</Label>
              <Input id="tickUpper" placeholder="0" />
            </div>
            <div className="flex flex-col space-y-1.5">
              <Label htmlFor="liquidity">Liquidity</Label>
              <Input id="liquidity" placeholder="0" />
            </div>
          </div>
        </form>
      </CardContent>
      <CardFooter className="flex justify-between">
        <Button variant="outline">Cancel</Button>
        <Button>Deploy</Button>
      </CardFooter>
    </Card>
        
      </main>
    </div>
  );
}
