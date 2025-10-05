using System;
using System.IO;
using System.Threading;
using System.Collections;
using System.Diagnostics;

namespace Xml;

/// @brief allows you to visit xml elements, passed to a XmlVisitorPipeline
/// 
/// ## Example:
/// ```
/// class FooVisitor : XmlVisitor
/// {
/// 	public override Options Flags => .SkipTags;
///
/// 	public override Result<void> Visit(XmlVisitable node)
/// 	{
///			Console.WriteLine($"{TagDepth} -> {node}");
/// 	}
/// }
///
/// XmlVisitorPipeline pipeline = scope .(new FooVisitor());
/// pipeline.Run(source);
/// ```
abstract class XmlVisitor
{
	public enum Options
	{
		None = 0,
		/// will skip opening and closing tags and opening ends
		SkipTags = 1,
		/// will include EOFs
		VisitEOF = _*2,
	}

	[AllowDuplicates]
	public enum Action
	{
		/// will pass node on to the next visitor
		Continue,
		/// will terminate execution on the current source
		Terminate,
		/// will terminate and print errors
		Error,
		/// will jump to the next node, skipping the rest of the visitors
		Skip,
	}

	/// eg. for <Foo><Bar><Baz> would be ("Foo", "Bar", "Baz")
	protected List<String> TagDepth { get; internal set; }
	protected MarkupSource CurrentSource { get; internal set; }
	protected XmlVisitorPipeline Pipeline { get; internal set; }
	protected BumpAllocator Alloc => Pipeline.Reader.[Friend]alloc;

	public abstract Options Flags { get; }

	public abstract Action Visit(ref XmlVisitable node);
	public virtual void Init() {}

	protected mixin Try(var result)
	{
		if (result case .Err)
			return .Error;
	}
}

/// allows you to insert visitables into the pipeline
abstract class XmlInsertVisitor : XmlVisitor
{
	/// will run the remaining visitiors on the input before continuing with the current visitable
	protected delegate void(XmlVisitable) InsertBeforeCurrent { get; internal set; }

	/// will act as if the current visitable were followed by the provided one
	protected delegate void(XmlVisitable) InsertAfterCurrent { get; internal set; }
}

abstract class XmlAsyncVisitor : XmlVisitor
{
	public abstract void VisitAsync(XmlVisitable node);

	public override Action Visit(ref XmlVisitable node)
		=> ThreadPool.QueueUserWorkItem(new () => { VisitAsync(node); } ) ? .Continue :
			{
				CurrentSource.Error(String.ConstF($"Something went wrong while queuing VisitAsync from {nameof(Self)}"));
				.Error
			};
}

/// implementing visitor will have a result of T once it terminates
interface IResultVisitor<T>
{
	public T Result { get; }
}

/// Note: takes ownership over visitors
class XmlVisitorPipeline
{
	/// specifies the stream to which errors will be printed
	public StreamWriter ErrorStream { protected get; set; } = Console.Error;

	public XmlHeader CurrentHeader { get; private set; }
	public XmlReader Reader { get; private set; }

	protected XmlVisitor[] pipeline ~ delete _;
	protected List<String> tagDepth = new .(16) ~ delete _;

	private bool hasInsertVisitors = false;

	public this(params Span<XmlVisitor> visitors)
	{
		pipeline = new .[visitors.Length];
		visitors.CopyTo(pipeline);
		for (let visitor in pipeline)
		{
			visitor.[Friend]TagDepth = tagDepth;
			visitor.[Friend]Pipeline = this;
			hasInsertVisitors = hasInsertVisitors || visitor is XmlInsertVisitor;
		}
	}

	public Result<void> Run(XmlReader reader)
	{
		CurrentHeader = Try!(reader.ParseHeader());
		Reader = reader;

		delegate void(XmlVisitable) queueNext = scope => reader.Cycle;

		for (let visitor in pipeline)
		{
			visitor.[Friend]CurrentSource = reader.source;
			if (!hasInsertVisitors) continue;
			let insertVisitor = visitor as XmlInsertVisitor;
			if (insertVisitor == null) continue;
			insertVisitor.[Friend]InsertAfterCurrent = queueNext;
			visitor.Init();
		}

		XmlVisitable node;
		bool root = true;
		node: repeat
		{
			node = reader.ParseNext(root);
			root = false;

			Result<(bool tag, bool eof)> Validate(XmlVisitable node)
			{
				bool tag = false, eof = false, popTag = false;
				switch (node)
				{
				case .OpeningTag(let name):
					tagDepth.Add(name);
					tag = true;
				case .OpeningEnd(let bodyless):
					tag = true;
					popTag = bodyless;
				case .ClosingTag(let name):
					if (tagDepth.Back != name)
					{
						reader.source.Error(new $"Element <{tagDepth.Back}> was not closed");
						return .Err;
					}
					tag = true;
					popTag = true;
				case .CharacterData, .Attribute:
				case .Err:
					return .Err;
				case .EOF:
					bool error = false;
					for (let element in tagDepth)
					{
						reader.source.Error(new $"Element <{element}> was not closed");
						error = true;
					}
					if (error) return .Err;
					eof = true;
				}
				return (tag, eof);
			}
			(bool tag, bool eof) = Try!(Validate(node));

			Result<void>? returning = null;
			mixin PerformAction(XmlVisitor.Action action)
			{
				switch (action)
				{
				case .Continue:
				case .Terminate:
					tagDepth.Clear();
					returning = .Ok;
					break mixin;
				case .Error:
					tagDepth.Clear();
					returning = .Err;
					break mixin;
				case .Skip:
					break mixin;
				}
			}
			
			visit: for (let visitor in pipeline.GetEnumerator())
			{
				if (tag && visitor.Flags.HasFlag(.SkipTags)) continue;
				if (eof && !visitor.Flags.HasFlag(.VisitEOF)) continue;
				if (hasInsertVisitors) do
				{
					let insertVisitor = visitor as XmlInsertVisitor;
					if (insertVisitor == null) break;
					insertVisitor.[Friend]InsertBeforeCurrent = scope:visit [&](val) => {
						if (returning != null) return;
						let result = Validate(val);
						if (result case .Err)
						{
							returning = .Err;
							return;
						}
						(bool tag, bool eof) = result;
						let copy = @visitor;
						var val;
						for (let left in copy)
						{
							if (returning != null) return;
							if (tag && visitor.Flags.HasFlag(.SkipTags)) continue;
							if (eof && !visitor.Flags.HasFlag(.VisitEOF)) continue;
							PerformAction!(left.Visit(ref val));
						}
						if (val case .OpeningEnd(true) || val case .ClosingTag)
							tagDepth.PopBack();
					};
				}

				PerformAction!(visitor.Visit(ref node));

				if (returning != null)
					return (.)returning;
			}

			if (node case .OpeningEnd(true) || node case .ClosingTag)
				tagDepth.PopBack();
		}
		while (!(node case .EOF));

		return .Ok;
	}
}