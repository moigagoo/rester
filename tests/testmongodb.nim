import unittest

import os, strutils, sequtils, times

import norm / mongodb


const
  # for local testing, modify your /etc/hosts file to contain "mongodb_1"
  # pointing to your local mongodb server
  dbConnection = "mongodb://mongodb_1:27017"
  dbName = "TestDb"
  customDbName = "TestCustomDb"

db(dbConnection, "", "", dbName):
  type
    User {.table: "users".} = object
      email {.unique.}: string
      ssn: Option[int]
      birthDate: Time
    Publisher {.table: "publishers".} = object
      title {.unique.}: string
    Book {.table: "books".} = object
      title: string
      authorEmail {.fk: User.email, onDelete: "CASCADE".}: string
      publisherTitle {.fk: Publisher.title.}: string
      ratings: seq[float]

  # TODO proc getBookById(id: Oid): Book = withDb(Book.getOne id)
  # TODO add and test foreign key pulls in mongo

  type
    Edition {.table: "editions".} = object
      title: string
      book: Book

suite "Creating and dropping tables, CRUD":
  setup:
    var 
      user_reference_id: array[1..9, Oid]
      publisher_reference_id: array[1..9, Oid]
      book_reference_id: array[1..9, Oid]
      edition_reference_id: array[1..9, Oid]

    withDb:
      createTables(force=true)

      for i in 1..9:
        var
          user = User(
            email: "test-$#@example.com" % $i, 
            ssn: some i,
            birthDate: parseTime("200$1-0$1-0$1" % $i, "yyyy-MM-dd", utc())
          )
          publisher = Publisher(
            title: "Publisher $#" % $i
          )
          book = Book(
            title: "Book $#" % $i, 
            authorEmail: user.email,
            publisherTitle: publisher.title,
            ratings: @[4.5, 9.6, 7.0]
          )
          edition = Edition(
            title: "Edition $#" % $i
          )

        user.insert()
        user_reference_id[i] = user.id
        publisher.insert()
        publisher_reference_id[i] = publisher.id
        book.insert()
        book_reference_id[i] = book.id

        edition.book = book
        edition.insert()
        edition_reference_id[i] = edition.id

  teardown:
    withDb:
      dropTables()

  test "Create records":
    withDb:
      let
        publishers = Publisher.getMany(100, sort = %*{"title": 1})
        books = Book.getMany(100, sort = %*{"title": 1})
        editions = Edition.getMany(100, sort = %*{"title": 1})

      check len(publishers) == 9
      check len(books) == 9
      check len(editions) == 9

      check publishers[3].title == "Publisher 4"

      check books[5].title == "Book 6"
      check books[5].ratings == @[4.5, 9.6, 7.0]

      check editions[7].title == "Edition 8"
      check editions[7].book == books[7]

  test "Read records":
    withDb:
      var
        users: seq[User] = @[]
        # users = User().repeat 10
        publishers = Publisher().repeat 10
        books = Book().repeat 10
        editions = Edition().repeat 10

      users.pullMany(20, offset=5, sort = %*{"ssn": 1})
      publishers.pullMany(20, offset=5, sort = %*{"title": 1})
      books.pullMany(20, offset=5, sort = %*{"title": 1})
      editions.pullMany(20, offset=5, sort = %*{"title": 1})

      check len(users) == 4
      check users[0].ssn.get() == 6
      check users[^1].ssn.get() == 9

      check len(publishers) == 4
      check publishers[0].title == "Publisher 6"
      check publishers[^1].title == "Publisher 9"

      check len(books) == 4
      check books[0].title == "Book 6"
      check books[^1].title == "Book 9"

      check len(editions) == 4
      check editions[0].title == "Edition 6"
      check editions[^1].title == "Edition 9"

      var
        user = User()
        publisher = Publisher()
        book = Book()
        edition = Edition()

      user.pullOne user_reference_id[8]
      publisher.pullOne publisher_reference_id[8]
      book.pullOne book_reference_id[8]
      edition.pullOne edition_reference_id[8]

      check user.ssn == some 8
      check publisher.title == "Publisher 8"
      check book.title == "Book 8"
      check edition.title == "Edition 8"

  test "Query records":
    withDb:
      let someBooks = Book.getMany(
        10,
        cond = %*{"title": {"$in": ["Book 1", "Book 5"]}},
        sort = %*{"title": -1}
      )

      check len(someBooks) == 2
      check someBooks[0].title == "Book 5"
      check someBooks[1].authorEmail == "test-1@example.com"

      let aBook = Book.getOne(book_reference_id[7])
      check aBook.title == "Book 7"
      let bBook = Book.getOne(%*{"authorEmail": "test-2@example.com"})
      check bBook.id == book_reference_id[2]

      var vBook = Book()
      vBook.pullOne(book_reference_id[6])
      check vBook.title == "Book 6"
      vBook.pullOne(%*{"authorEmail": "test-4@example.com"})
      check vBook.title == "Book 4"
      check vBook.id == book_reference_id[4]

      expect NotFound:
        let notExistingBook = Book.getOne(%*{"title": "Does not exist"})

  test "Update records":
    withDb:
      var
        book = Book.getOne book_reference_id[2]
        edition = Edition.getOne edition_reference_id[2]

      book.title = "New Book"
      edition.title = "New Edition"

      check book.update() == true
      check edition.update() == true

    withDb:
      check Book.getOne(book_reference_id[2]).title == "New Book"
      check Edition.getOne(edition_reference_id[2]).title == "New Edition"

  test "Delete records":
    withDb:
      var
        book = Book.getOne book_reference_id[2]
        edition = Edition.getOne edition_reference_id[2]

      book.delete()
      check edition.delete() == true

      expect NotFound:
        discard Book.getOne book_reference_id[2]

      expect NotFound:
        discard Edition.getOne edition_reference_id[2]

  # test "Custom DB":
  #   withCustomDb(customDbName, "", "", ""):
  #     createTables(force=true)

  #   withCustomDb(customDbName, "", "", ""):
  #     let query = "PRAGMA table_info($#);"

  #     check dbConn.getAllRows(sql query % "users") == @[
  #       @[dbValue 0, dbValue "id", dbValue "INTEGER", dbValue 1, dbValue nil, dbValue 1],
  #       @[dbValue 1, dbValue "email", dbValue "TEXT", dbValue 1, dbValue nil, dbValue 0],
  #       @[dbValue 2, dbValue "ssn", dbValue "INTEGER", dbValue 0, dbValue nil, dbValue 0],
  #       @[dbValue 3, dbValue "birthDate", dbValue "INTEGER", dbValue 1, dbValue nil, dbValue 0]
  #     ]
  #     check dbConn.getAllRows(sql query % "books") == @[
  #       @[dbValue 0, dbValue "id", dbValue "INTEGER", dbValue 1, dbValue nil, dbValue 1],
  #       @[dbValue 1, dbValue "title", dbValue "TEXT", dbValue 1, dbValue nil, dbValue 0],
  #       @[dbValue 2, dbValue "authorEmail", dbValue "TEXT", dbValue 1, dbValue nil, dbValue 0],
  #       @[dbValue 3, dbValue "publisherTitle", dbValue "TEXT", dbValue 1, dbValue nil, dbValue 0],
  #     ]
  #     check dbConn.getAllRows(sql query % "editions") == @[
  #       @[dbValue 0, dbValue "id", dbValue "INTEGER", dbValue 1, dbValue nil, dbValue 1],
  #       @[dbValue 1, dbValue "title", dbValue "TEXT", dbValue 1, dbValue nil, dbValue 0],
  #       @[dbValue 2, dbValue "bookId", dbValue "INTEGER", dbValue 1, dbValue nil, dbValue 0]
  #     ]

  #   withCustomDb(customDbName, "", "", ""):
  #     dropTables()

  #     expect DbError:
  #       dbConn.exec sql "SELECT NULL FROM users"
  #       dbConn.exec sql "SELECT NULL FROM publishers"
  #       dbConn.exec sql "SELECT NULL FROM books"
  #       dbConn.exec sql "SELECT NULL FROM editions"

  #   removeFile customDbName

  # removeFile dbName
