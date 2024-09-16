"use client"

import { TrendingUp } from "lucide-react"
import { LabelList, Pie, PieChart } from "recharts"

import {
  Card,
  CardContent,
  CardDescription,
  CardFooter,
  CardHeader,
  CardTitle,
} from "@/components/ui/card"
import {
  ChartConfig,
  ChartContainer,
  ChartTooltip,
  ChartTooltipContent,
} from "@/components/ui/chart"

export const description = "A pie chart with a label list"

const chartData = [
  { chain: "baseSepolia", percentage: 40, fill: "var(--color-baseSepolia)" },
  { chain: "sepolia", percentage: 60, fill: "var(--color-sepolia)" },
]

const chartConfig = {
  percentage: {
    label: "Percentage",
  },
  baseSepolia: {
    label: "Base Sepolia",
    color: "hsl(var(--chart-1))",
  },
  sepolia: {
    label: "Sepolia",
    color: "hsl(var(--chart-2))",
  },
} satisfies ChartConfig

export function StrategyPieChart() {
  return (
    <Card className="flex flex-col">
      <CardHeader className="items-center pb-0">
        <CardTitle>Liquidity Split</CardTitle>
        <CardDescription>Base Sepolia and Sepolia</CardDescription>
      </CardHeader>
      <CardContent className="flex-1 pb-0">
        <ChartContainer
          config={chartConfig}
          className="mx-auto aspect-square max-h-[250px]"
        >
          <PieChart>
            <ChartTooltip
              content={<ChartTooltipContent nameKey="percentage" hideLabel />}
            />
            <Pie data={chartData} dataKey="percentage">
              <LabelList
                dataKey="chain"
                className="fill-background"
                stroke="none"
                fontSize={12}
                formatter={(value: keyof typeof chartConfig) =>
                  chartConfig[value]?.label
                }
              />
            </Pie>
          </PieChart>
        </ChartContainer>
      </CardContent>
      {/* <CardFooter className="flex-col gap-2 text-sm">
        <div className="flex items-center gap-2 font-medium leading-none">
          Trending up by 5.2% this month <TrendingUp className="h-4 w-4" />
        </div>
        <div className="leading-none text-muted-foreground">
          Showing total visitors for the last 6 months
        </div>
      </CardFooter> */}
    </Card>
  )
}
