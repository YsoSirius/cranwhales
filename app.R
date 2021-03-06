library(shiny)
library(shinydashboard)
library(readr)
library(dplyr)
library(ggplot2)
library(DT)
library(glue)
library(lubridate)
library(gdata)  # for gdata::humanReadable

source("random-names.R")
source("modules/detail.R")

ui <- dashboardPage(
  dashboardHeader(
    title = "CRAN whales"
  ),
  dashboardSidebar(
    dateInput("date", "Date", value = Sys.Date() - 3),
    numericInput("count", "Show top N downloaders:", 6)
  ),
  dashboardBody(
    fluidRow(
      tabBox(width = 12,
        tabPanel("All traffic",
          fluidRow(
            valueBoxOutput("total_size", width = 4),
            valueBoxOutput("total_count", width = 4),
            valueBoxOutput("total_downloaders", width = 4)
          ),
          plotOutput("all_hour")
        ),
        tabPanel("Biggest whales",
          plotOutput("downloaders", height = 500)
        ),
        tabPanel("Whales by hour",
          plotOutput("downloaders_hour", height = 500)
        ),
        tabPanel("Detail view",
          detailViewUI("details")
        )
      )
    )
  )
)

server <- function(input, output, session) {
  
  ### Reactive expressions ============================================
  
  # Downloads data from cran-logs.rstudio.com, and parses it.
  # Successful downloads are stored in the data_cache dir.
  data <- eventReactive(input$date, ignoreNULL = FALSE, {
    date <- input$date
    validate(need(is.Date(date), "Invalid date"))
    
    year <- lubridate::year(date)
    
    url <- glue("http://cran-logs.rstudio.com/{year}/{date}.csv.gz")
    path <- file.path("data_cache", paste0(date, ".csv.gz"))
    
    withProgress(value = NULL, {
      
      # Download to a temporary file path, then rename to the real
      # path when the download is complete. We do this so other
      # processes/sessions don't use partially downloaded files.
      if (!file.exists(path)) {
        tmppath <- paste0(path, "-", Sys.getpid())
        setProgress(message = "Downloading data...")
        download.file(url, tmppath)
        if (!file.exists(path)) {
          file.rename(tmppath, path)
        } else {
          file.remove(tmppath)
        }
      }
      
      setProgress(message = "Parsing data...")
      read_csv(path, col_types = "Dti---c-ci", progress = FALSE)
      
    })
  })
  
  # Returns a data frame of just the top `input$count` downloaders of the day,
  # with the columns: 
  # ip_id - an arbitrary integer that's used in place of the real IP address
  # ip_name - the same as ip_id but using easier-to-remember labels like
  #     "quant_weasel" or "nutritious_lovebird".
  # n - the number of downloads performed by this IP on this day
  whales <- reactive({
    validate(
      need(is.numeric(input$count), "Invalid top downloader count"),
      need(input$count > 0, "Too few downloaders"),
      need(input$count <= 25, "Too many downloaders; 25 or fewer please")
    )
    data() %>%
      count(ip_id, country) %>%
      arrange(desc(n)) %>%
      head(input$count) %>%
      mutate(ip_name = factor(ip_id, levels = ip_id,
        labels = glue("{random_name(length(ip_id), input$date)} [{country}]"))) %>%
      select(-country)
  })
  
  # data(), filtered down to the downloads that are by the top `input$count`
  # downloaders
  whale_downloads <- reactive({
    data() %>%
      inner_join(whales(), "ip_id") %>%
      select(-n)
  })

  
  ### Outputs =========================================================
  
  #### "All traffic" tab ----------------------------------------
  
  output$total_size <- renderValueBox({
    data() %>%
      pull(size) %>%
      as.numeric() %>%  # Cast from integer to numeric to avoid overflow warning
      sum() %>%
      humanReadable() %>%
      valueBox("bandwidth consumed")
  })
  
  output$total_count <- renderValueBox({
    data() %>%
      nrow() %>%
      format(big.mark = ",") %>%
      valueBox("files downloaded")
  })
  
  output$total_uniques <- renderValueBox({
    data() %>%
      pull(package) %>%
      unique() %>%
      length() %>%
      format(big.mark = ",") %>%
      valueBox("unique packages")
  })
  
  output$total_downloaders <- renderValueBox({
    data() %>%
      pull(ip_id) %>%
      unique() %>%
      length() %>%
      format(big.mark = ",") %>%
      valueBox("unique downloaders")
  })
  
  output$all_hour <- renderPlot({
    whale_ip <- whales()$ip_id
    
    data() %>%
      mutate(
        time = hms::trunc_hms(time, 60*60),
        is_whale = ip_id %in% whale_ip
      ) %>%
      count(time, is_whale) %>%
      ggplot(aes(time, n, fill = is_whale)) +
      geom_bar(stat = "identity") +
      scale_fill_manual(values = c("#666666", "#88FF99"),
        labels = c("no", "yes")) +
      ylab("Downloads") +
      xlab("Hour") +
      scale_y_continuous(labels = scales::comma)
  })
  
  #### "Biggest whales" tab -------------------------------------
  
  output$downloaders <- renderPlot({
    whales() %>%
      ggplot(aes(ip_name, n)) +
      geom_bar(stat = "identity") +
      ylab("Downloads on this day")
  })
  
  #### "Whales by hour" tab -------------------------------------
  
  output$downloaders_hour <- renderPlot({
    whale_downloads() %>%
      mutate(time = hms::trunc_hms(time, 60*60)) %>%
      count(time, ip_name) %>%
      ggplot(aes(time, n)) +
      geom_bar(stat = "identity") +
      facet_wrap(~ip_name) +
      ylab("Downloads") +
      xlab("Hour")
  })
  
  #### "Detail view" tab ----------------------------------------

  callModule(detailView, "details", whales, whale_downloads)
}

shinyApp(ui, server)
