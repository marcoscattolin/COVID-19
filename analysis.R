library(drc)
library(tidyverse)
library(lubridate)
library(forecast)




# HELPERS -------------------------------------------------------------
load_ts <- function(){
        confirmed <- read_csv(("./csse_covid_19_data/csse_covid_19_time_series/time_series_covid19_confirmed_global.csv")) %>% 
                gather(date, confirmed, -`Province/State`, -`Country/Region`, -Lat, -Long) %>% 
                mutate(date = mdy(date)) %>% 
                rename(country = `Country/Region`) %>% 
                group_by(country,date) %>% 
                summarise(confirmed = sum(confirmed))
        deaths <- read_csv(("./csse_covid_19_data/csse_covid_19_time_series/time_series_covid19_deaths_global.csv")) %>% 
                gather(date, deaths, -`Province/State`, -`Country/Region`, -Lat, -Long) %>% 
                mutate(date = mdy(date)) %>% 
                rename(country = `Country/Region`) %>% 
                group_by(country,date) %>% 
                summarise(deaths = sum(deaths))
        recovered <- read_csv(("./csse_covid_19_data/csse_covid_19_time_series/time_series_covid19_recovered_global.csv")) %>% 
                gather(date, recovered, -`Province/State`, -`Country/Region`, -Lat, -Long) %>% 
                mutate(date = mdy(date)) %>% 
                rename(country = `Country/Region`) %>% 
                group_by(country,date) %>% 
                summarise(recovered = sum(recovered))
        
        df <- confirmed %>% inner_join(deaths) %>% inner_join(recovered)
        
        df <- df %>% 
                group_by(country) %>% 
                mutate(new_confirmed = confirmed-lag(confirmed)) %>% 
                mutate(new_deaths = deaths-lag(deaths)) %>% 
                mutate(new_recovered = recovered-lag(recovered)) %>% 
                mutate(new_confirmed_growthrate = (confirmed/lag(confirmed))-1) %>% 
                mutate(sick_population = confirmed-recovered-deaths) %>% 
                replace_na(list(confirmed  = 0, deaths  = 0, recovered  = 0, new_confirmed  = 0, new_deaths  = 0, new_recovered  = 0, new_confirmed_growthrate  = 0, sick_population = 0))
        
        
}





get_timeseries_df <- function(df, training_end, ref_country = "Italy"){
        
        country_ts <- df %>% 
                ungroup() %>% 
                filter(country == ref_country) %>% 
                filter(deaths > 0) 
        
        country_ts %>% 
                mutate(y = (deaths)) %>% 
                mutate(x = row_number()) %>% 
                mutate(series = case_when(date > training_end ~ "Validation", TRUE ~ "Training"))
        
        
}





fit_linear <- function(ts_df, h = 10){
        
        # convert to ts object
        timeseries <- ts_df %>% filter(series == "Training") %>% pull(y) %>% ts()
        
        # calculate start of forecast dates
        trng_start_date <- ts_df %>% filter(series == "Training") %>% pull(date) %>% min()
        
        # fit model and make fcst
        arima_model <- timeseries %>% auto.arima() %>% forecast(h)
        
        # extract data
        fitted_linear <- autolayer(arima_model)$layer_data()
        fitted_linear %>%
                filter(level %in% c(NA, 80)) %>% 
                replace_na(list(y = 0, ymin = 0, ymax = 0)) %>% 
                group_by(x) %>% 
                summarise_at(vars(y, ymin, ymax), sum) %>% 
                mutate(series = "Linear model") %>%
                mutate(date = trng_start_date+x-1)
        
        
        
}


fit_exponential <- function(ts_df, h = 10){
        
        # convert to ts object
        timeseries <- ts_df %>% filter(series == "Training") %>% pull(y) %>% log() %>% ts() 
        
        # calculate start of forecast dates
        trng_start_date <- ts_df %>% filter(series == "Training") %>% pull(date) %>% min()
        
        # fit model and make fcst
        arima_model <- timeseries %>% auto.arima() %>% forecast(h)
        
        # extract data
        fitted_linear <- autolayer(arima_model)$layer_data()
        fitted_linear %>%
                filter(level %in% c(NA, 80)) %>% 
                replace_na(list(y = 0, ymin = 0, ymax = 0)) %>% 
                group_by(x) %>% 
                summarise_at(vars(y, ymin, ymax), sum) %>% 
                mutate(series = "Exponential model") %>%
                mutate(date = trng_start_date+x-1) %>%
                mutate_at(vars(y, ymin, ymax), exp)
        
        
        
}

fit_logistic <- function(ts_df, inflection_point=NA, h=10){
        
        timeseries <- ts_df %>% filter(series == "Training") %>% select(x, y)
        log_curve <- drm(y ~ x, data = timeseries, fct = L.3(fixed = c(NA, NA, inflection_point)), type = "continuous")
        
        # calculate start of forecast dates
        trng_start_date <- ts_df %>% filter(series == "Training") %>% pull(date) %>% min()
        
        
        # make future df
        x_start <- max(timeseries$x) + 1
        x_end <- max(timeseries$x) + h
        future_df <- tbl_df(list(x = x_start:x_end))
        
        # predict
        predictions <- predict(log_curve, newdata = as.data.frame(future_df), interval = "confidence", level=.90) %>% tbl_df()
        
        # extract data
        future_df %>% 
                bind_cols(predictions) %>% 
                mutate(series = "Logistic model") %>% 
                mutate(date = trng_start_date+x-1) %>% 
                rename(y = Prediction, ymax = Lower, ymin = Upper)
        
        
        
}


fit_gompertz <- function(ts_df, h=10){
        
        timeseries <- ts_df %>% filter(series == "Training") %>% select(x, y)
        gomp_curve <- drm(y ~ x, data = timeseries, fct = G.3(), type = "continuous")
        
        # calculate start of forecast dates
        trng_start_date <- ts_df %>% filter(series == "Training") %>% pull(date) %>% min()
        
        
        # make future df
        x_start <- max(timeseries$x) + 1
        x_end <- max(timeseries$x) + h
        future_df <- tbl_df(list(x = x_start:x_end))
        
        # predict
        predictions <- predict(gomp_curve, newdata = as.data.frame(future_df), interval = "confidence", level=.90) %>% tbl_df()
        
        # extract data
        future_df %>% 
                bind_cols(predictions) %>% 
                mutate(series = "Gompertz model") %>% 
                mutate(date = trng_start_date+x-1) %>% 
                rename(y = Prediction, ymax = Lower, ymin = Upper)
        
        
        
}



get_errors <- function(df){
        
        # get validation data
        validation <- df %>% filter(series == "Validation") %>% select(date, x, y) %>% rename(actual = y)
        
        # get forecasts
        forecast <- df %>% filter(!(series %in% c("Training", "Validation"))) %>% select(date, x, y, series) %>% rename(forecast = y)
        
        # join datasets
        forecast <- validation %>% inner_join(forecast, by = c("date", "x"))
        
        # calculate errors
        forecast %>% 
                mutate(perc_error = (actual-forecast)/forecast) %>% 
                mutate(error = (actual-forecast)) %>% 
                arrange(series, x)
        
}



# MAIN --------------------------------------------------------------------
HORIZON <- 30
TRAINING_END <- as.Date("2020-04-15")


# load data
global_ts <- load_ts()


# extract country and define training window
country_ts_df <- get_timeseries_df(ref_country = "Italy",
                                   df = global_ts, 
                                   training_end = TRAINING_END)


# fit models
fitted_df <- country_ts_df %>% 
        #bind_rows(fit_linear(country_ts_df, h = HORIZON)) %>% 
        #bind_rows(fit_exponential(country_ts_df,  h = HORIZON)) %>% 
        bind_rows(fit_logistic(country_ts_df,  h = HORIZON)) %>% 
        bind_rows(fit_gompertz(country_ts_df,  h = HORIZON))

# calculate errors
errors_df <- get_errors(fitted_df)




# plot models
fitted_df %>% 
        ggplot(aes(x = date, y = y, col = series, group = series)) +
        geom_point() +
        geom_line() + 
        ggtitle("Comparison of different models") +
        theme_bw()




# plot each model with confint
models <- c("Gompertz model", "Logistic model")

for (i in models){
        g <- fitted_df %>% 
                filter(date >= as.Date("2020-02-24")) %>% 
                filter(series %in% c("Training", "Validation", i)) %>% 
                ggplot(aes(x = date, y = y, col = series, group = series)) +
                geom_point() +
                geom_line() + 
                geom_line(aes(y = ymax), lty = "dashed") +
                geom_line(aes(y = ymin), lty = "dashed") +
                ggtitle(i) +
                theme_bw()
        
        if (i == "Exponential model") {
                g <- g + scale_y_log10()
                
        }
        plot(g)
        
}



# plot models around traingin end date
fitted_df %>% 
        filter(series %in% c("Training", "Logistic model", "Gompertz model", "Validation")) %>% 
        filter(date >= TRAINING_END-3) %>% 
        filter(date <= TRAINING_END+10) %>% 
        ggplot(aes(x = date, y = y, col = series, group = series)) +
        geom_point() +
        geom_line() + 
        #geom_label(aes(label = round(y/1000, 2), fill = series), col = I("black")) +
        ggtitle("Forecast of models w. labels") +
        scale_y_log10() +
        theme_bw()


# plot errors on oos data
errors_df %>%
        ggplot(aes(y = perc_error, x = series, fill = series)) +
        geom_boxplot() +
        geom_jitter() +
        theme_bw() +
        coord_flip()






# display plateau
country_ts_df %>% 
        bind_rows(fit_gompertz(country_ts_df,  h = 100)) %>% #select(date,y,ymin,ymax) %>% tail()
        select(date, x,y, ymin, ymax, series) %>% 
        ggplot(aes(x = date, y = y, col = series)) +
        geom_line() +
        geom_line(aes(y=ymin), lty = "dashed") +
        geom_line(aes(y=ymax), lty = "dashed") +
        theme_bw() +
        ggtitle("Plateau")


# display next dates
fitted_df %>% 
        filter(date >= Sys.Date()-2) %>% 
        filter(date <= Sys.Date()+2) %>% 
        select(date, deaths, y, ymin, ymax, series) %>% 
        filter(series %in% c("Validation", "Training", "Gompertz model"))

