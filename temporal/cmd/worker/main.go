package main

import (
	"log"
	"os"

	"go.temporal.io/sdk/client"
	"go.temporal.io/sdk/worker"

	"symphony-temporal/internal/activities"
	"symphony-temporal/internal/workflows"
)

func main() {
	address := envOr("TEMPORAL_ADDRESS", "localhost:7233")
	namespace := envOr("TEMPORAL_NAMESPACE", "default")
	taskQueue := envOr("TEMPORAL_TASK_QUEUE", "symphony")

	c, err := client.Dial(client.Options{
		HostPort:  address,
		Namespace: namespace,
	})
	if err != nil {
		log.Fatalf("unable to create Temporal client: %v", err)
	}
	defer c.Close()

	w := worker.New(c, taskQueue, worker.Options{})
	w.RegisterWorkflow(workflows.IssueRunWorkflow)
	w.RegisterActivity(activities.RunIssueJob)

	log.Printf("worker started on %s (%s/%s)", taskQueue, address, namespace)
	if err := w.Run(worker.InterruptCh()); err != nil {
		log.Fatalf("worker failed: %v", err)
	}
}

func envOr(key, fallback string) string {
	if value := os.Getenv(key); value != "" {
		return value
	}
	return fallback
}
