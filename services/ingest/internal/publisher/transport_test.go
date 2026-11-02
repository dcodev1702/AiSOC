package publisher

import (
	"testing"

	"github.com/beenuar/aisoc/services/ingest/internal/config"
)

func TestEachTopicWriterHasAnIndependentConnectionPool(t *testing.T) {
	t.Setenv("ENVIRONMENT", "development")
	t.Setenv("KAFKA_SECURITY_PROTOCOL", "PLAINTEXT")

	pub, err := New(&config.Config{
		KafkaBrokers:      "broker:9092",
		KafkaTopic:        "aisoc.raw_events",
		MaxBatchSize:      100,
		VulnCorrelEnabled: true,
		VulnKafkaTopic:    "aisoc.vulnerability_matches",
		GraphUpdatesTopic: "security.graph_updates",
	})
	if err != nil {
		t.Fatal(err)
	}
	defer pub.Close()

	if pub.writer.Transport == pub.vulnWriter.Transport {
		t.Fatal("raw-event and vulnerability writers share a Kafka transport")
	}
	if pub.writer.Transport == pub.graphWriter.Transport {
		t.Fatal("raw-event and graph writers share a Kafka transport")
	}
	if pub.vulnWriter.Transport == pub.graphWriter.Transport {
		t.Fatal("vulnerability and graph writers share a Kafka transport")
	}
}
