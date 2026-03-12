from pyflink.datastream import StreamExecutionEnvironment

env = StreamExecutionEnvironment.get_execution_environment()

# Instead of from_collection, read from Redpanda/Kafka directly
from pyflink.datastream.connectors import FlinkKafkaConsumer
from pyflink.common.serialization import SimpleStringSchema
from pyflink.common.typeinfo import Types

kafka_props = {'bootstrap.servers': 'redpanda:9092', 'group.id': 'flink-demo'}

consumer = FlinkKafkaConsumer(
    topics='construction.events',
    deserialization_schema=SimpleStringSchema(),
    properties=kafka_props
)

ds = env.add_source(consumer)

# basic map to parse JSON
import json
ds = ds.map(lambda x: json.loads(x), output_type=Types.MAP(Types.STRING(), Types.STRING()))

# print for demo purposes
ds.print()

env.execute("Construction Stream Processor")
