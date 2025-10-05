using Json;
using System;
using System.IO;
using System.Collections;
using System.Diagnostics;

namespace Json.Test;

static
{
	const let input = @"""
		{
			"array": [
				"first\n",
				"second\n"
			],
			"null": null,
			"int": 25,
			"float": 4.2
		}
		""";

	[Test]
	static void TestJsonReader()
	{
		StringStream stream = scope .(input, .Reference);
		MarkupSource source = scope .(scope .(stream), "input");
		JsonReader reader = scope .(source);
		JsonElement output = reader.Parse();

		Test.Assert(output case .Object(let object));
		Test.Assert(object["null"] case .Null);
		Test.Assert(object["int"] case .Int(25));
		Test.Assert(object["float"] case .Float(4.2));
		Test.Assert(object["array"] case .Array(let array));
		Test.Assert(array[0] case .String("first\n"));
		Test.Assert(array[1] case .String("second\n"));
	}

	[Test]
	static void TestJsonBuilder()
	{
		StringStream stream = scope .(input, .Reference);
		MarkupSource source = scope .(scope .(stream), "input");
		JsonReader reader = scope .(source);
		JsonElement output = reader.Parse();
		JsonBuilder builder = scope .(Console.Out);
		builder.Write(output);
	}

	class TestBar
	{
		public int a = 25;
		public double b;
		public Foo foo;

		public enum Foo
		{
			case foo, bar(int), @null;
		}
	}

	[Test]
	static void TestJsonSerialze()
	{
		const let input = """
			{
				"b": 15.2,
				"foo": "null"
			}
			""";

		StringStream stream = scope .(input, .Reference);
		MarkupSource source = scope .(scope .(stream), "input");
		JsonReader reader = scope .(source);
		let bar = Json.Deserialize<JsonSchema>(reader, false).Get();
		/*Test.Assert(bar.a == 25);
		Test.Assert(bar.b == 15.2);
		Test.Assert(bar.foo case .@null);*/
	}
}