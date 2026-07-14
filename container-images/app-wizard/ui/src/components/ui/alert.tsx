import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "@/lib/utils";

const alertVariants = cva("relative w-full rounded-lg border p-3 text-sm", {
  variants: {
    variant: {
      default: "border-border bg-background text-foreground",
      destructive: "border-destructive/50 bg-destructive/5 text-destructive",
      warning: "border-warning/50 bg-warning/10 text-warning-foreground",
      info: "border-primary/40 bg-primary/5 text-foreground",
      success: "border-success/40 bg-success/10 text-success",
    },
  },
  defaultVariants: { variant: "default" },
});

export interface AlertProps
  extends React.HTMLAttributes<HTMLDivElement>,
    VariantProps<typeof alertVariants> {}

export function Alert({ className, variant, ...props }: AlertProps) {
  return <div role="alert" className={cn(alertVariants({ variant }), className)} {...props} />;
}

export function AlertTitle({ className, ...props }: React.HTMLAttributes<HTMLHeadingElement>) {
  return <h5 className={cn("mb-1 font-medium leading-none", className)} {...props} />;
}

export function AlertDescription({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return <div className={cn("text-sm [&_p]:leading-relaxed", className)} {...props} />;
}
