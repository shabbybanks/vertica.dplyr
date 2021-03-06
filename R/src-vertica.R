####################################################################
#A dplyr connector for the Vertica database.
#Copyright (C) [2015] Hewlett-Packard Development Company, L.P.

#This program is free software; you can redistribute it and/or modify
#it under the terms of the GNU General Public License as published by
#the Free Software Foundation; either version 2 of the License, or (at
#your option) any later version.

#This program is distributed in the hope that it will be useful, but
#WITHOUT ANY WARRANTY; without even the implied warranty of
#MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
#General Public License for more details.  You should have received a
#copy of the GNU General Public License along with this program; if
#not, write to the Free Software Foundation, Inc., 59 Temple Place,
#Suite 330, Boston, MA 02111-1307 USA
#####################################################################

setClass("VerticaConnection",  representation = representation(conn = "ANY", type = "character"))

.VerticaConnection <- function(conn,type) {
  new("VerticaConnection",conn=conn,type=type)
}

#' Establishes a connection to Vertica and returns a dplyr 'src' object, src_vertica, using either vRODBC or JDBC.
#'
#' Provide either the DSN to use ODBC, or set DSN to NULL to use JDBC.
#'
#' @param dsn The name of the ODBC DSN to use for connecting to Vertica. Must be a string. If NULL, JDBC-use is assumed.
#' @param jdbcpath (Only required for JDBC) Path to the JDBC driver on your system.
#' @param dbname (Only required for JDBC) The name of the Vertica database instance that you plan to connect to.
#' @param host (Only required for JDBC) Host IP of the machine hosting the Vertica instance.
#' @param port (Only required for JDBC) Port number of the Vertica server. The Vertica default is 5433.
#' @param user (Only required for JDBC) Username of the owner of the database.
#' @param password (Only required for JDBC) Password, if any, of the database.
#' @param load_udf A boolean value. If TRUE (default), this will automatically register the UDFs into the session.
#' @return A dplyr::src object, src_vertica, to be used with dplyr functions.
#' @examples
#' \dontrun{
#' vertica_connection <- src_vertica(dsn="VerticaDSN")
#' vertica_connection <- src_vertica(dsn=NULL,jdbcpath="/opt/vertica/java/lib/vertica_jdbc.jar",
#'                                   dbname="foo",host="localhost",port=5433,
#'                                   user="dbadmin",password="secret")
#' }
#' @import methods
#' @import assertthat
#' @import dplyr
#' @export
src_vertica <- function(dsn = NULL, jdbcpath = NULL, dbname = NULL, host = NULL, port = 5433, user = NULL, password = "", load_udf=TRUE) {
  if(is.null(jdbcpath) && is.null(dsn)){
    stop("Must provide either the ODBC DSN driver name or the CLASSPATH to your Vertica JDBC Driver, e.g., src_vertica(...,dsn=\"VerticaDSN\") or src_vertica(...,jdbcpath=\"/opt/vertica/java/lib/vertica_jdbc.jar\")")
  }
 
  if(!is.null(dsn)) {
    .attemptLoad("vRODBC")
    odbcCloseAll()
    assert_that(is.character(dsn))
    conn <- odbcConnect(dsn)
    info <- odbcGetInfo(conn)  
    type <- "ODBC"
  }else {
    assert_that(is.character(jdbcpath))
    assert_that(is.numeric(port))
    .attemptLoad("RJDBC")
    host <- as.character(host)
    port <- as.character(port)
    type <- "JDBC"
  
    drv <- JDBC(driverClass = "com.vertica.jdbc.Driver",classPath = jdbcpath)
    conn <- dbConnect(drv,paste0("jdbc:vertica://",host,":",port,"/",dbname),user=user,password=password)
  }

  con <- .VerticaConnection(conn=conn,type=type)

  if(checkDB(con)){
    if(type=="JDBC"){
      info <- list()
      info$host <- host
      info$port <- port
      info$user <- user
      info$dbname <- dbname
      info$type <- paste0(type, " Connection")
    }
  } else {
    stop("Stop error: Could not establish a valid connection to a Vertica database.")
  }

  vsrc <- src_sql("vertica", con = con, info = info)

  if(load_udf) {
    import_udf(vsrc)
  }
  
  vsrc
}

# Describes the connection
#' @export
src_desc.src_vertica <- function(x) {
  info <- x$info
    
  if(x$con@type == "JDBC"){
    host <- ifelse(is.null(info$host),"localhost",info$host)

    paste0("Vertica ", info$type, " [", info$user, "@",
      host, ":", info$port, "/", info$dbname, "]")
  }else{
    paste0("Vertica ", "ODBC Connection", "\n-----+DSN: ",info["Data_Source_Name"], "\n-----+Host: ", info["Server_Name"], 
    "\n-----+DB Version: ", info["DBMS_Ver"], "\n-----+ODBC Version: ", info["Driver_ODBC_Ver"])
  }
}

#' @export
tbl.src_vertica <- function(src, from, ...) {
  tbl_sql("vertica", src = src, from = from, ...)
}



#' Loads a file (typically CSV) from disk to Vertica.
#'
#' Currently, this will only work for tables that already exist with compatible
#' schema for the table.
#'
#' This loading is fast and is used (by default) in copy_to.
#'
#' @param dest Vertica connection src to the DB.
#' @param table.name The name of the table created in Vertica matching the schema
#' of the file.
#' @param file.name Path to file with data.
#' @param sep Delimiter in the file.
#' @param skip Number of lines to skip at the beginning of the file (useful if contains headers).
#' @param append TRUE if copied data will be added to existing data in table. FALSE to overwrite table data.
#' @return A new tbl_vertica reference to the loaded table.
#' @examples
#' \dontrun{
#' vertica <- src_vertica("VerticaDSN")
#' foo <- db_load_from_file(vertica,"foo","./foo.csv",sep=",")
#' }
#' @export
db_load_from_file <- function(dest, table.name, file.name, sep = " ", skip = 1L, append = FALSE){
  assert_that(is.character(table.name))
  assert_that(is.character(file.name), file.exists(file.name))

  assert_that(is.character(sep))
  assert_that(class(dest)[1] == "src_vertica")

  if(!db_has_table(dest$con, table.name)) stop("The specified table does not exist in Vertica.")

  skip <- ifelse(skip >=0,as.integer(skip),0L)

  itable <- ident_schema_table(table.name)

  table.nrow <- db_query_rows(vertica$con, 
  	     build_sql("SELECT * FROM ", sql(table.name)))

  if(!append && table.nrow > 0) {
    delete_sql <- build_sql("DELETE FROM ", itable)
    send_query(dest$con@conn, delete_sql)
  }

  copy_sql <- build_sql("COPY ", itable, " FROM LOCAL ", file.name,
         " WITH DELIMITER AS ", sep, " NULL AS 'NA'", " SKIP ", skip, " ABORT ON ERROR", con = dest$con)

  tryCatch({result = send_query(dest$con@conn, copy_sql)
            if(class(result) == "character" 
               && length(result) >=2
               && substring(result[2],1,14) == "[vRODBC] ERROR")
                 {
                   stop(result)
                 }
           },
           warning=function(w) {
             warning(w)}, 
           error = function(e) {
             stop(e)}
          )   
             
  tbl(dest, table.name)
} 

#' @export
copy_to.src_vertica <- function(dest, df, name = deparse(substitute(df)),
                           temporary=FALSE, append=FALSE, fast.load=TRUE, ...) {

  assert_that(is.data.frame(df), is.string(name))
  has_table <- db_has_table(dest$con, name)

  if(!append) {

    if(has_table) {
      warning(name, " already exists.")
      ans <- readline(prompt = paste0("Replace existing table named `", name, "`?(y/n) "))
      if(substring(ans,1,1) != "y" && substring(ans,1,1) != "Y") return()
      else db_drop_table(dest$con, name)
    }

    types <- db_data_type(dest$con, df)
    names(types) <- names(df)

    if(temporary) warning("Copying to a temporary table is not supported. Writing to a permanent table.")
    db_create_table(dest$con, name, types, temporary=FALSE)
  } else {
    if(!has_table)
      stop("Cannot append to non-existing table ", name, ".")
  }

  if(fast.load) {
    tmpfilename = paste0("/tmp/", "dplyr_", name, ".csv")
    write.table(df, file=tmpfilename, sep=",", row.names=FALSE, quote=FALSE)
    db_load_from_file(dest, name, tmpfilename, append=append, sep=",", skip=1L)
    file.remove(tmpfilename)
  }
  else {
    db_insert_into(dest$con, name, df)
  }

  db_analyze(dest$con, name)

  tbl(dest, name)
}

#' @export
db_create_table.src_vertica <- function(src, table, types, temporary=FALSE, ...)
{
  db_create_table(src$con, table, types, temporary, ...)
}

#' @export
db_create_table.VerticaConnection <- function(con, table, types, temporary=FALSE, ...) {
  assert_that(is.string(table), is.character(types))
  if(db_has_table(con, table)) stop("Table name already exists")

  field_names <- escape(ident(names(types)), collapse = NULL, con = con)
  fields <- dplyr:::sql_vector(paste0(field_names, " ", types), parens = TRUE,
                               collapse = ", ", con = con)

  sql <- build_sql("CREATE ", if(temporary) sql("TEMPORARY "), "TABLE ", ident_schema_table(table), " ", fields, con = con)

  #invisible(send_query(con@conn, sql))
  send_query(con@conn, sql)

  if(!db_has_table(con, table)) stop("Could not create table; are the data types specified in Vertica-compatible format?")
}

# Currently slow for bulk insertions
db_insert_into.VerticaConnection <- function(con, table, values, ...) {
  cols <- lapply(values, escape, collapse = NULL, parens = FALSE, con = con)
  col_mat <- matrix(unlist(cols, use.names = FALSE), nrow = nrow(values))
  coltypes <- unname(db_data_type(con, values))

  col_mat <- apply(col_mat,1, function(x){suppressWarnings(apply(cbind(x,coltypes),1,function(y){
    if(y[1] == "NULL") y[1] = paste0("CAST(",y[1]," AS ",y[2],")")
    y[1]
    })) 
  })

  col_mat <- t(col_mat)
  all_rows <- apply(col_mat, 1, paste0, collapse = ", ")
  block_size = 2000;
  num_blocks = ceiling(length(all_rows)/block_size)

  for(a in 1:num_blocks){
    start = (a-1) * block_size + 1
    end = start + block_size - 1
    end = min(length(all_rows),end)

    rows <- all_rows[start:end]
    last_row <- tail(rows,1)
    last_row <- paste0("SELECT ",last_row)
    formatted_rows <- paste0("SELECT ",rows,"\nUNION ALL")
    formatted_rows[length(formatted_rows)] <- last_row;

    sql <- build_sql(paste0("INSERT INTO ", ident_schema_table(table), "\n", sql(paste(formatted_rows, collapse="\n"))))
    sql <- gsub("''","'",sql)
    sql <- substr(sql,2,nchar(sql)-1)
    send_query(con@conn, sql)
   }
}

#' Saves a tbl object as a view in Vertica.
#'
#' If the save is defined to be temporary (non-default behavior), the view will be deleted
#' upon termination of the session.
#' 
#' Note that all views (temporary and permanent) are treatable as tbl objects in vertica.dplyr.
#'
#' @param table The local R-variable name of the tbl_vertica object to be saved as a view in Vertica.
#' @param name The name with which to associate the new view in Vertica.
#' @param temporary (Default: FALSE) TRUE if the saved view is to be a local temporary one. Note that saving locally will reduce 
#' available parallelism to the native data loader. 
#' @return A new tbl_vertica reference to the saved view.
#' @examples
#' \dontrun{
#' vertica <- src_vertica("VerticaDSN")
#' table1 <- tbl(vertica,"some_table")
#' table1_modified <- filter(table1,foo > 3)
#' new_view <- db_save_view(table1_modified,name="some_table_filtered")
#' }
#' @export
db_save_view <- function(table, name, temporary = FALSE) {
  v_sql <- build_sql("CREATE ", if (temporary) sql("LOCAL TEMPORARY "),"VIEW ", ident_schema_table(name),
    " AS ", table$query$sql, con = table$src$con)
  send_query(table$src$con@conn, v_sql)
  message(paste0("Created ", ifelse(temporary,"temporary ",""), "view ","`",name,"`."))
  update(tbl(table$src, name), group_by = groups(table))
}

#' @export
db_save_query.VerticaConnection <- function(con, sql, name, temporary = FALSE,...){
  if(temporary) temporary = sql("TEMPORARY")
  else temporary = sql("")
  t_sql <- build_sql("CREATE ", temporary, " TABLE ", ident_schema_table(name), " AS ", sql, con = con)
  send_query(con@conn, t_sql)
  name
}

#' @export
db_save_query.src_vertica <- function(src, sql, name, temporary = FALSE,...) {
  db_save_query(src$con, sql, name, temporary,...)
}

#' @export
db_list_tables.VerticaConnection <- function(con) {
  tbl_query <- "SELECT schema_name,table_name FROM all_tables WHERE table_type NOT IN (\'SYSTEM TABLE\')"
  if(con@type=="ODBC") {
    res <- sqlQuery(con@conn,tbl_query)
  }
  else {
    res <- dbGetQuery(con@conn,tbl_query)
  }

  mapply(function(x,y) {
    if(as.character(x) != getOption("dplyr.vertica_default_schema")) {
      y <- paste0('"', as.character(x), '"."', as.character(y), '"')
    }
    as.character(y)
  }, res[[1]], res[[2]])
}

#' @export
db_list_tables.src_vertica <- function(src) {
  db_list_tables(src$con)
}

#' @export
db_has_table.src_vertica <- function(src, table) {
  db_has_table(src$con, table)
}

#' @export
db_has_table.VerticaConnection <- function(con, table) {
  assert_that(is.string(table))

  st <- get_schema_table(table)
  tbl_query <- paste0("SELECT COUNT(*) N FROM all_tables WHERE lower(table_name)=\'", tolower(st$table),
                      "\' AND lower(schema_name)=\'", tolower(st$schema),"\'")
  res <- send_query(con@conn, tbl_query, useGetQuery=TRUE)
  res$N > 0
}

#' @export
db_drop_table.src_vertica <- function(src, table, force = FALSE, ...) {
  db_drop_table(src$con, table, force, ...)
}

#' @export
db_drop_table.VerticaConnection <- function(con, table, force = FALSE, ...) {
  assert_that(is.string(table))

  if(!db_has_table(con, table)) stop("Table does not exist in database.")

  sql <- build_sql("DROP TABLE ", if (force) sql("IF EXISTS "), ident_schema_table(table),
    con = con)
  send_query(con@conn, sql)
}

#' @export
db_drop_view.src_vertica <- function(src, view) {
  db_drop_view(src$con, view)
}

#' Like db_drop_table, but for views.
#'
#' @param con dplyr src connection object 
#' @param view The name of the view in DB to drop.
#' @export
db_drop_view <- function(con, view) {
  UseMethod("db_drop_view")
}

#' @method db_drop_view VerticaConnection
#' @export
db_drop_view.VerticaConnection <- function(con, view) {
  assert_that(is.string(view))

  if(!db_has_table(con, view)) stop("View does not exist in database.")

  sql <- build_sql("DROP VIEW ", ident_schema_table(view),
    con = con)
  send_query(con@conn, sql)
}

#' @export
db_query_fields.VerticaConnection <- function(con, sql, addAlias=FALSE, ...){
  assert_that(is.string(sql), is.sql(sql))

  from <- sql
  if(is.schema_table(sql)) from <- ident_schema_table(sql)


  if(addAlias || !db_has_table(vertica$con, sql)) 
  	      from <- paste0("(",from,") AS FOO")

  fields <- paste0("SELECT * FROM ", from, " WHERE 0=1")
  qry <- send_query(con@conn, fields, useGetQuery=TRUE)
  names(qry)
}

#' @export
db_query_rows.VerticaConnection <- function(con, sql, ...) {
  assert_that(is.string(sql), is.sql(sql))
  from <- if(is.schema_table(sql)) ident_schema_table(sql)
          else sql_subquery(con, sql, "master")
  rows <- paste0("SELECT count(*) FROM ", from)
  as.integer(send_query(con@conn, rows, useGetQuery=TRUE)[[1]])
}

# Explains queries
#' @export
db_explain.VerticaConnection <- function(con, sql, ...) {
  exsql <- build_sql("EXPLAIN ", sql, con = con)
  output <- send_query(con@conn, exsql, useGetQuery=TRUE)
  output <- apply(output,1,function(x){
    if(substring(x,1,1) == "|") x = paste0("\n",x)
    if(x == "") x = "\n"
    x
  })

  graphVizInd <- match("PLAN: BASE QUERY PLAN (GraphViz Format)",output)
  output[1:(graphVizInd-4)]
}


#' @export
sql_escape_ident.VerticaConnection <- function(con, x) {
  sql_quote(x,'"')
}

# Analyze for performance
#' @export
db_analyze.VerticaConnection <- function(con, table, ...) {
   assert_that(is.string(table))

   query <- build_sql("SELECT ANALYZE_STATISTICS('", gsub('"','', ident_schema_table(table)), "')")
   send_query(con@conn, query, useGetQuery=TRUE)
}


 db_create_indexes.VerticaConnection <- function(con, table, indexes = NULL, unique = FALSE, ...) 
{
  warning("User-created indexes are unsupported")
}

#' @export
db_create_index.VerticaConnection <- function(con, table, columns, name = NULL,
                                             ...) {
  warning("User-created indexes are unsupported")
}

#' @export
db_data_type.VerticaConnection <- function(con, fields, ...) {
  vapply(fields, get_data_type, FUN.VALUE=character(1))
}

get_data_type <- function(val, ...) {
            if (is.integer(val)) "INTEGER"
            else if (is.numeric(val)) "DOUBLE PRECISION"
            else "VARCHAR(255)"
}

                          
setGeneric("checkDB", function (con) {
  standardGeneric("checkDB")
})

setMethod("checkDB", "VerticaConnection", function(con) {
  if(con@type == "JDBC") out <- .jcall(con@conn@jc,"Z","isValid",as.integer(1))
  else {
    tryCatch({sqlQuery(con@conn, "SELECT * FROM system_tables LIMIT 1")
      out <- TRUE},
      error=function(e){
        out <- FALSE
      })  
  }
  out
})

# Lifted from dplyr package -- only change is adding parens argument and relaxing over arguments requirement
over <- function(expr, partition = NULL, order = NULL, frame = NULL, parens = FALSE) {

  if (!is.null(partition)) {
    partition <- build_sql("PARTITION BY ",
      dplyr:::sql_vector(partition, collapse = ", ",parens))
  }
  if (!is.null(order)) {
    order <- build_sql("ORDER BY ", dplyr:::sql_vector(order, collapse = ", ",parens))
  }
  if (!is.null(frame)) {
    if (is.numeric(frame)) frame <- dplyr:::rows(frame[1], frame[2])
    frame <- build_sql("ROWS ", frame)
  }

  over <- dplyr:::sql_vector(dplyr:::compact(list(partition, order, frame)), parens = TRUE)
  build_sql(expr, " OVER ", over)
}

send_query <- function(conn, query, useGetQuery=FALSE, ...) UseMethod("send_query")

send_query.JDBCConnection <- function(conn, query, useGetQuery=FALSE) {
  if(useGetQuery) dbGetQuery(conn,query)
  else dbSendUpdate(conn,query)
}

send_query.vRODBC <- function(conn, query, ...) {
  out <- sqlQuery(conn,query)
  if(class(out) == "character")
	{
		errors = grepl("Exception in processPartitionForR", out)
		if(any(errors))
		{
			out = out[errors]
			out = out[1]
			stop(out)
		}
		errors = grepl("ERROR", out)
		if(any(errors))
		{
			out = out[errors]
			out = out[1]
			stop(out)
		}

	}
  out
}

getSchemas <- function(con) {
  schemasQuery <- "SELECT table_schema,table_name from tables"
  send_query(con@conn,schemasQuery) 
}


.attemptLoad <- function(depName, ...) {
  if(depName %in% (.packages())) return()
  tryCatch({message(paste0("Attempting to load package `", depName, "` and its dependencies..."))
    suppressPackageStartupMessages(library(depName,character.only=TRUE))
    message("Successfully loaded.")
    }, error = function(e) {
      msg <- switch(depName,
             RJDBC = "Could not load one or more of the required JDBC packages: RJDBC, DBI and rJava. Please install.",
             vRODBC = "Could not load the required vRODBC package. Please download it from GitHub: https://github.com/vertica/DistributedR/tree/master/vRODBC ", 
             HPdata = "Could not load one or more of HPdata and/or Distributed R and their dependencies. Please download: https://github.com/vertica/DistributedR/ " )
      stop(msg)
    })
}

sql_subquery.VerticaConnection <- dplyr:::sql_subquery.SQLiteConnection

collect.tbl_vertica <- function(x, ..., n = Inf, warn_incomplete = TRUE)
{
    assert_that(length(n) == 1, n > 0L)
    if (n == Inf) {
        n <- -1
    }
    sql <- sql_render(x)
    if( as.integer(n) > 0)
    { 
	if(  "name" %in% names(x$ops))
	{
	    if(x$ops$name != "head" && x$ops$name != "tail")
	    {
    	    	sql <- build_sql(sql, " LIMIT ", as.integer(n))
	    }
	}
	else
	{
	    sql <- build_sql(sql, " LIMIT ", as.integer(n))
	}

    }
    out <- send_query(x$src$con@conn, sql)
    if(n > 0)
    	head(out,n)
    else
	out
}


sql_build.op_udf <- function(op, con, ...)
{
    subquery <- sql_build(op$x, con)


    group_vars <- sql(op_grps(op$x))
    order_vars <- sql(op_sort(op$x))

    if(length(group_vars) == 0)
    	group_vars = NULL
    if(length(order_vars) == 0)
        order_vars = NULL

    object <- list()
    object$from <- subquery
    object$partition = group_vars
    object$order = order_vars
    object$args = op$args


    object$expr = partial_eval(op$dots)
    class(object) <- "udf_query"
    return(object)
}

sql_render.udf_query <- function (query, con = NULL, ..., root = FALSE)
{
    from <- sql_render(query$from, root = root)
    sub_query_fields <- db_query_fields(con, from)
    function_expr <- NULL
    function_partition <- NULL
    function_order <- NULL


    if(!is.null(query$partition))
	function_partition = dplyr::translate_sql_(query$partition,
		con = con, vars = sub_query_fields, 
    		window = FALSE)
    if(!is.null(query$order))
	function_order = dplyr::translate_sql_(query$order,
		con = con, vars = sub_query_fields, 
    		window = FALSE)

     query <- lapply(query$expr, dplyr::translate_sql_,
     	window = TRUE, 
	vars = db_query_fields(con, from),
	con = con,
	vars_group = function_partition, 
	vars_order = function_order)
	
     query <- sql_vector(query, parens = FALSE, collapse = ",")
     from <- sql_subquery(con, from)
     query <- build_sql("SELECT ", query, " FROM ", from)
     return(query)

}


execute_udf <- function(.data, ...)
{
	
	.dots <- lazyeval::lazy_dots( ...)
	
	add_op_single("udf", .data, dots = .dots) 
}

select_.tbl_vertica <- function(.data, ..., .dots)
{
    expr <- partial_eval(.dots) 
    possible_udf <- lapply(expr, function(x){
    	if(length(x) > 1)
		 return(x[[1]])
	else
		 return(x)
	})
    transform_udx_list <- list_udf(vertica, "Transform") 
    transform_udx_list <- as.character(transform_udx_list$function.names)



    udx = sapply(transform_udx_list, 
    	function(x) grepl(x, possible_udf, ignore.case = TRUE))
    if(sum(udx) == 1)
    {
    dots <- lazyeval::all_dots(.dots, ...)
    add_op_single("udf", .data, dots = dots, args = list(udx = udx))
    }
    else if(sum(udx) == 0)
    {
	dplyr:::select_.tbl_lazy(.data, ..., .dots = .dots)
    }
    else
    {
	stop("Can only have 1 transform function per select statement")
    }
}


select_.src_vertica <- function(.data, ..., .dots)
{
    new_table <- make_tbl(c("vertica", "sql", "lazy"), src = .data, 
    	      ops = structure(list(src = .data, dots = .dots, name = "system_query"), class = c("op_system")))
    new_table$ops$vars = op_vars(new_table$ops)
    return (new_table)
    
}

sql_build.op_system <- function(op, con, ...)
{
    expr <- partial_eval(op$dots) 
    object = list(expr = expr)
    class(object) <- "system_query"
    return(object)
}

sql_render.system_query <- function (query, con = NULL, ..., root = FALSE)
{

    query_sql = lapply(query$expr, dplyr::translate_sql_, 
		con = con, 
    		window = FALSE)

    query_sql <- sql_vector(query_sql, parens = FALSE, collapse = ",")
    query_sql <- build_sql("SELECT ", query_sql)
    return(query_sql)

}

op_vars.op_system <- function(op)
{
	if(is.null(op$vars))
	{
		query <- sql_render(sql_build(op, op$src), op$src)
		#op$vars <- names(send_query(op$src$con@conn, query))
		op$vars <- NULL
	}
	return(op$vars)
}

op_grps.op_system <- function(op)
{
	NULL
}

op_sort.op_system <- function(op)
{
	NULL
}

#  utility function stolen from dplyr.		
commas <- function(...) paste0(..., collapse = ", ")

print.tbl_vertica <- function (x, ..., n = NULL, width = NULL) 
{
    cat("Source:   query ", dim_desc(x), "\n", sep = "")
    cat("Database: ", src_desc(x$src), "\n", sep = "")
    grps <- op_grps(x$ops)
    if (length(grps) > 0) {
        cat("Groups: ", commas(op_grps(x$ops)), "\n", sep = "")
    }
    cat("\n")
    if( "name" %in% names(x$ops))
    {
    	if(x$ops$name == "system_query")
    	{
		results <- collect(x)
		if(!is.null(n))
			results <- head(results,n)
		print(results)
    	}
    	else
    	{
		print(trunc_mat(x, n = n, width = width))
    	}
    }
    invisible(x)
}
