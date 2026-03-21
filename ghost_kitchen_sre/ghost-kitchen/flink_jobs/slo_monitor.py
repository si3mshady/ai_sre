import json, logging, time
from pyflink.datastream import StreamExecutionEnvironment
from pyflink.datastream.connectors.kafka import FlinkKafkaConsumer, FlinkKafkaProducer
from pyflink.common.serialization import SimpleStringSchema
from pyflink.common.typeinfo import Types
from pyflink.datastream.window import SlidingEventTimeWindows
from pyflink.common.time import Time, Duration
from pyflink.common.watermark_strategy import WatermarkStrategy
from pyflink.datastream.functions import ProcessWindowFunction, KeyedProcessFunction

class SustainedBreachFilter(KeyedProcessFunction):
    """Ensures we only alert if SLO is breached for 2 consecutive windows."""
    def __init__(self):
        self.breach_count = None

    def open(self, runtime_context):
        from pyflink.common.state import ValueStateDescriptor
        self.breach_count = runtime_context.get_state(ValueStateDescriptor("breach_count", Types.INT()))

    def process_element(self, value, ctx):
        data = json.loads(value)
        current_count = self.breach_count.value() or 0
        
        if data['p95_prep'] > 8.0:
            current_count += 1
        else:
            current_count = 0
            # Explicitly emit NORMAL status so Agent can verify recovery
            yield json.dumps({**data, "alert_type": "NORMAL"})
        
        self.breach_count.update(current_count)
        
        if current_count >= 2:
            yield json.dumps({**data, "alert_type": "SLO_VIOLATION", "sustained_count": current_count})

class KitchenWindowProcess(ProcessWindowFunction):
    def process(self, key, context, elements):
        orders = [json.loads(e) if isinstance(e, str) else e for e in elements]
        if not orders: return
        
        prep_times = sorted([o.get('prep_time_required', 0) for o in orders])
        p95_prep = prep_times[int(0.95 * (len(prep_times) - 1))]
        
        yield json.dumps({
            'station': key,
            'p95_prep': round(p95_prep, 2),
            'order_count': len(orders),
            'timestamp': time.time()
        })

def main():
    env = StreamExecutionEnvironment.get_execution_environment()
    brokers = "redpanda-0.redpanda.kitchen-sre.svc.cluster.local:9092"
    
    consumer = FlinkKafkaConsumer(['t1_kitchen.orders'], SimpleStringSchema(), {"bootstrap.servers": brokers})
    
    watermark_strategy = WatermarkStrategy.for_monotonous_timestamps() \
        .with_timestamp_assigner(lambda x, _: int(json.loads(x).get('timestamp', 0) * 1000))

    ds = env.add_source(consumer.set_start_from_latest())

    # Windowing logic
    agg_stream = (
        ds.assign_timestamps_and_watermarks(watermark_strategy)
        .key_by(lambda x: json.loads(x).get('station', 'unknown'))
        .window(SlidingEventTimeWindows.of(Time.seconds(10), Time.seconds(5)))
        .process(KitchenWindowProcess(), output_type=Types.STRING())
    )

    # Sustained Breach Filter
    alert_stream = (
        agg_stream.key_by(lambda x: json.loads(x).get('station'))
        .process(SustainedBreachFilter(), output_type=Types.STRING())
    )

    alert_stream.add_sink(FlinkKafkaProducer('t1_kitchen.alerts', SimpleStringSchema(), {"bootstrap.servers": brokers}))
    env.execute("Sustained Breach Monitor")

if __name__ == "__main__":
    main()
