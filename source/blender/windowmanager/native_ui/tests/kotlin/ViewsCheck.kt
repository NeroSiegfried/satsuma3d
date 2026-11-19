// SPDX-FileCopyrightText: 2026 Blender Authors
//
// SPDX-License-Identifier: GPL-2.0-or-later

// What an Android shell does with the protocol, in Kotlin: an update as Blender writes it, each
// node in a buffer of its own, applied to the nodes a view keeps; then a command sent back. Run by
// `kotlin_check.py`, which compiles it with the generated code.

import Blender.NativeUI.*
// Explicitly, over Kotlin's own of the same names.
import Blender.NativeUI.Number
import com.google.flatbuffers.FlatBufferBuilder
import java.nio.ByteBuffer

/** A node of a view, kept in a buffer of its own, as a shell keeps it. */
class KeptNode(val node: Node, var children: List<String> = emptyList())

fun check(condition: Boolean, what: String) {
    if (!condition) throw AssertionError(what)
}

/** A node as Blender sends it: its own buffer, written into the update as bytes. */
fun nodeBuffer(builder: FlatBufferBuilder, write: (FlatBufferBuilder) -> Int): Int {
    val node = FlatBufferBuilder(64)
    node.finish(write(node))
    val bytes = node.sizedByteArray()
    val vector = NodeBuffer.createNodeVector(builder, bytes.toUByteArray())
    return NodeBuffer.createNodeBuffer(builder, vector)
}

fun update(): ByteBuffer {
    val builder = FlatBufferBuilder(256)
    val panel = nodeBuffer(builder) { b ->
        val key = b.createString("panel:transform")
        val label = b.createString("Transform")
        val content = Panel.createPanel(b, true, false, false, -1, true)
        Node.startNode(b)
        Node.addKey(b, key)
        Node.addContentType(b, Content.Panel)
        Node.addContent(b, content)
        Node.addLabel(b, label)
        Node.endNode(b)
    }
    val location = nodeBuffer(builder) { b ->
        val key = b.createString("location_x")
        val label = b.createString("X")
        val content = Number.createNumber(b, 1.5, false, NumberKind.Distance, Double.NEGATIVE_INFINITY,
                                          Double.POSITIVE_INFINITY, -10.0, 10.0, 0.1, 3u, false,
                                          Scale.Linear, 0, 0.0)
        Node.startNode(b)
        Node.addKey(b, key)
        Node.addContentType(b, Content.Number)
        Node.addContent(b, content)
        Node.addLabel(b, label)
        Node.endNode(b)
    }
    val nodes = Update.createNodesVector(builder, intArrayOf(panel, location))
    val keys = Children.createKeysVector(builder, intArrayOf(builder.createString("location_x")))
    val children = Children.createChildren(builder, builder.createString("panel:transform"), keys)
    val childrenVector = Update.createChildrenVector(builder, intArrayOf(children))
    val top = builder.createString("panel:transform")
    val update = Update.createUpdate(builder, 1u, 1u, true, top, nodes, childrenVector, 0)
    val updates = Updates.createUpdatesVector(builder, intArrayOf(update))
    builder.finish(Updates.createUpdates(builder, updates, 0))
    return builder.dataBuffer()
}

/** Apply an update to a view's nodes, as a shell does. */
fun apply(buffer: ByteBuffer, nodes: MutableMap<String, KeptNode>) {
    val updates = Updates.getRootAsUpdates(buffer)
    for (i in 0 until updates.updatesLength) {
        val update = updates.updates(i)!!
        if (update.reset) nodes.clear()
        for (j in 0 until update.nodesLength) {
            /* Copied out, so it outlives the update. */
            val bytes = update.nodes(j)!!.nodeAsByteBuffer
            val own = ByteBuffer.allocate(bytes.remaining()).put(bytes).flip() as ByteBuffer
            val node = Node.getRootAsNode(own)
            nodes[node.key] = KeptNode(node, nodes[node.key]?.children ?: emptyList())
        }
        for (j in 0 until update.childrenLength) {
            val children = update.children(j)!!
            nodes[children.parent]?.children = (0 until children.keysLength).map { children.keys(it)!! }
        }
        for (j in 0 until update.removedLength) nodes.remove(update.removed(j))
    }
}

/** A command setting a number, as a drag's end sends it. */
fun command(): ByteBuffer {
    val builder = FlatBufferBuilder(64)
    val target = builder.createString("location_x")
    val value = FloatValue.createFloatValue(builder, 2.25)
    val command = Command.createCommand(builder, 7u, 1u, target, Op.Set, Value.FloatValue, value, Phase.End, 0, 0u)
    builder.finish(Commands.createCommands(builder, Commands.createCommandsVector(builder, intArrayOf(command))))
    return builder.dataBuffer()
}

fun main() {
    val nodes = mutableMapOf<String, KeptNode>()
    apply(update(), nodes)
    val panel = nodes["panel:transform"]!!
    check(panel.node.contentType == Content.Panel, "the panel is a panel")
    check((panel.node.content(Panel()) as Panel).expanded, "the panel is open")
    check(panel.children == listOf("location_x"), "the panel holds the number")
    val number = nodes["location_x"]!!.node.content(Number()) as Number
    check(number.value == 1.5 && number.kind == NumberKind.Distance, "the number reads back")

    val commands = Commands.getRootAsCommands(command())
    val sent = commands.commands(0)!!
    check(sent.target == "location_x" && sent.op == Op.Set && sent.phase == Phase.End, "the command reads back")
    check((sent.value(FloatValue()) as FloatValue).value == 2.25, "the command's value reads back")
    println("Kotlin reads and writes the protocol.")
}
