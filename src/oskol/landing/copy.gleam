//// Landing-page prose. The words themselves live with the rest of the
//// presentation (OskolWeb.GameCopy) and reach a handler through the copy
//// capability; the decision of which of them a page gets is here.

pub type Copy {
  Copy(
    title: String,
    description: String,
    intro: String,
    rules: List(String),
    faq: List(#(String, String)),
  )
}

pub type Site {
  Site(title: String, description: String)
}
