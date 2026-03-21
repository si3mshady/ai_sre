import json
import logging
import time
from pyflink.datastream import StreamExecutionEnvironment
from pyflink.datastream.connectors.kafka import FlinkKafkaConsumer, FlinkKafkaProducer
from pyflink.common.serialization import SimpleStringSchema
from pyflink.common.typeinfo import Types
from pyflink.datastream.window import SlidingEventTimeWindows
from pyflink.common.time import Time, Duration
from pyflink.common.watermark_strategy import WatermarkStrategy, TimestampAssigner
from pyflink.datastream.functions import ProcessWindowFunction, KeyedProcessFunction

# --- TIMESTAMP ASSIGNER FIX ---
class OrderTimestampAssigner(TimestampAssigner):
    """Fixes the AttributeError by providing a proper interface implementation."""
    def extract_timestamp(self, value, record_timestamp):
        try:
            data = json.loads(value)
            # Flink expects milliseconds
            return int(data.get('timestamp', time.time()) * 1000)
        except Exception:
            return int(time.time() * 1000)

# --- PROCESSING LOGIC ---
class SustainedBreachFilter(KeyedProcessFunction):
    """
    Ensures we only alert if SLO is breached for 2 consecutive windows.
    Refactored to use in-memory dictionary to avoid pyflink.common.state issues.
    """
    def __init__(self):
        # Using a dictionary to track counts per station key in-memory
        self.breach_tracker = {}

    def process_element(self, value, ctx):
        data = json.loads(value)
        station = data.get('station', 'unknown')
        
        # Initialize or get current count
        current_count = self.breach_tracker.get(station, 0)
        
        # Threshold set to 8.0s per runbook
        if data.get('p95_prep', 0) > 8.0:
            current_count += 1
        else:
            # If it drops below threshold, reset and emit NORMAL
            if current_count > 0:
                yield json.dumps({**data, "alert_type": "NORMAL"})
            current_count = 0
        
        # Update in-memory state
        self.breach_tracker[station] = current_count
        
        # Trigger alert if threshold met
        if current_count >= 2:
            yield json.dumps({
                **data, 
                "alert_type": "SLO_VIOLATION", 
                "sustained_count": current_count
            })

class KitchenWindowProcess(ProcessWindowFunction):
    """Calculates p95 and window metrics."""
    def process(self, key, context, elements):
        orders = [json.loads(e) if isinstance(e, str) else e for e in elements]
        if not orders:
            return
        
        prep_times = sorted([o.get('prep_time_required', 0) for o in orders])
        # Calculate p95 index
        idx = max(0, int(0.95 * (len(prep_times) - 1)))
        p95_prep = prep_times[idx]
        
        yield json.dumps({
            'station': key,
            'p95_prep': round(float(p95_prep), 2),
            'order_count': len(orders),
            'timestamp': time.time()
        })

def main():
    env = StreamExecutionEnvironment.get_execution_environment()
    # Parallelism of 1 ensures our in-memory dictionary sees all data for a station
    env.set_parallelism(1) 
    
    brokers = "redpanda-0.redpanda.kitchen-sre.svc.cluster.local:9092"
    
    # 1. Consumer for raw orders
    consumer = FlinkKafkaConsumer(
        ['t1_kitchen.orders'], 
        SimpleStringSchema(), 
        {"bootstrap.servers": brokers, "group.id": "flink-sre-monitor"}
    )
    
    # 2. Correct Watermark Strategy
    watermark_strategy = WatermarkStrategy.for_monotonous_timestamps() \
        .with_timestamp_assigner(OrderTimestampAssigner())

    ds = env.add_source(consumer.set_start_from_latest())

    # 3. Windowing (Aggregates raw orders into metrics)
    agg_stream = (
        ds.assign_timestamps_and_watermarks(watermark_strategy)
        .key_by(lambda x: json.loads(x).get('station', 'unknown'))
        .window(SlidingEventTimeWindows.of(Time.seconds(10), Time.seconds(5)))
        .process(KitchenWindowProcess(), output_type=Types.STRING())
    )

    # 4. Telemetry Sink (for Dashboard visualization)
    telemetry_producer = FlinkKafkaProducer(
        't1_kitchen.telemetry', 
        SimpleStringSchema(), 
        {"bootstrap.servers": brokers}
    )
    agg_stream.add_sink(telemetry_producer)

    # 5. Sustained Breach Filter (Refactored Alerting Logic)
    alert_stream = (
        agg_stream.key_by(lambda x: json.loads(x).get('station'))
        .process(SustainedBreachFilter(), output_type=Types.STRING())
    )

    # 6. Sink Alerts for the SRE Agent
    alert_producer = FlinkKafkaProducer(
        't1_kitchen.alerts', 
        SimpleStringSchema(), 
        {"bootstrap.servers": brokers}
    )
    alert_stream.add_sink(alert_producer)

    print("🚀 Flink SLO Monitor started. Streaming Telemetry and Alerts...")
    env.execute("Sustained Breach Monitor")

if __name__ == "__main__":
    main()
