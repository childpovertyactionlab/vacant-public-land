library(tidyverse)
library(sf)
library(cpaltemplates)
library(googlesheets4)

libDB <- "C:/Users/Michael/CPAL Dropbox/" #dropbox directory
libGH <- "C:/Users/Michael/Documents/GitHub/" #github directory

cleanOwners <- read_sheet(ss = "https://docs.google.com/spreadsheets/d/1_mMM9Smz4LndqW-fFx0O5VuIAyvIG3oLxvUdtMbv9Ys/", sheet = "pubDallas")

#countOWners <- cleanOwners %>%
#  group_by(OWNERSHIP_GROUP) %>%
#  summarize(TOT_ACCOUNTS = sum(TOT_ACCOUNTS))

dallas <- st_read(paste0(libDB, "Data Library/Data.gdb"), layer = "Dallas_Simple") %>%
  st_transform(crs = 2276)
#st_crs(dallas)

# import parcel and owner data 
accounts <- rio::import(paste0(libDB, "Data Library/Parcel Data/DCAD/2023 Certified/account_info.csv"))
parcels <- st_read(paste0(libDB, "Data Library/Parcel Data/DCAD/2023 Certified/PARCEL2023/PARCEL2023.shp")) %>%
  st_transform(crs = 2276) %>%
  .[dallas, ]

accountAppr <- rio::import(paste0(libDB, "Data Library/Parcel Data/DCAD/2023 Certified/account_apprl_year.csv"))
resDet <- rio::import(paste0(libDB, "Data Library/Parcel Data/DCAD/2023 Certified/res_detail.csv"))
comDet <- rio::import(paste0(libDB, "Data Library/Parcel Data/DCAD/2023 Certified/com_detail.csv"))

# vacant accounts only 
vacant <- accountAppr %>%
  filter(SPTD_CODE %in% c("C11", "C12", "C13", "C14"))
  
# join cleaned owner names to parcel accounts
publicAccounts <- accounts %>%
  left_join(., cleanOwners) %>%
  filter(!is.na(OWNERSHIP_GROUP))

multiOwners <- publicAccounts %>%
  group_by(GIS_PARCEL_ID) %>%
  summarize(count = n(),
            unique = length(unique(OWNERSHIP_GROUP))) %>%
  arrange(desc(unique), desc(count)) %>%
  filter(unique > 1)

multiAccounts <- publicAccounts %>%
  filter(GIS_PARCEL_ID %in% multiOwners$GIS_PARCEL_ID)

# rename ownership group column for parcels with multiple accounts
publicClean <- publicAccounts %>%
  mutate(OWNERSHIP_GROUP = ifelse(GIS_PARCEL_ID %in% multiAccounts$GIS_PARCEL_ID, "MULTIPLE OWNERS", OWNERSHIP_GROUP)) %>%
  inner_join(., vacant)

countParcels <- publicClean %>%
  group_by(GIS_PARCEL_ID) %>%
  summarize(count = n())

countmult <- countParcels %>%
  filter(count > 1)

# parcels with public ownership only
publicParcel <- parcels %>%
  filter(Acct %in% countParcels$GIS_PARCEL_ID) %>%
  rename(GIS_PARCEL_ID = Acct) %>%
  left_join(., publicClean) %>%
  distinct(geometry, .keep_all = TRUE)

#plot(publicParcel["geometry"])

ownergrp <- publicParcel %>%
  st_drop_geometry(.) %>%
  group_by(OWNERSHIP_GROUP) %>%
  summarize(count = n())

publicDallas <- publicParcel %>%
  filter(OWNERSHIP_GROUP %in% c("CITY OF DALLAS", "DART", "DALLAS ISD", "MULTIPLE OWNERS", "DALLAS HOUSING AUTHORITY", "DALLAS COUNTY", "DALLAS COLLEGE"))

plot(publicDallas["OWNERSHIP_GROUP"])

# import mask layer and cut against that
maskDallas <- st_read(paste0(libDB, "Data Library/Data.gdb"), layer = "Dallas_MaskLayer_WaterParks") %>%
  st_transform(crs = 2276) %>%
  st_union()

plot(maskDallas)

invtParcels <- st_difference(publicDallas, maskDallas)

plot(invtParcels["OWNERSHIP_GROUP"])

st_write(invtParcels, "data/Public Land in the City of Dallas.geojson", delete_dsn = TRUE)
