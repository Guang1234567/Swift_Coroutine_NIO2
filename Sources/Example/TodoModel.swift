struct Todo: Codable {
    var id: Int
    var title: String
    var completed: Bool
}

// Our fancy todo "database". Since it is
// immutable it is webscale and lock free.
let todos = [
    Todo(id: 42, title: "Buy beer",
         completed: false),
    Todo(id: 1337, title: "Buy more beer",
         completed: false),
    Todo(id: 88, title: "Drink beer",
         completed: true)
]