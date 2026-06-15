try {
    throw Error("Test")
} finally {
    FileAppend("Finally`n", "*")
}
FileAppend("Surived`n", "*")
