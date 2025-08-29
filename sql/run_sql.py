import sys
import os
import json
import uuid
import logging

import boto3
import psycopg2

logging.basicConfig()
logger = logging.getLogger()
logger.setLevel(logging.INFO)

PATH = f"{sys.argv[3]}/"

def read_config(env: str):
    logger.info("Reading config")
    with open(f"{PATH}config_sql.json") as file:
        config = json.load(file)
    
    data = config[env]
    role_create = "scripts/role_create.sql" in data
    if role_create:
        data.remove("scripts/role_create.sql")

    return data, role_create

def get_secret_value(secret: str):
    client = boto3.client('secretsmanager')
    return json.loads(client.get_secret_value(SecretId=secret)['SecretString'])

def put_secret_value(secret: str, value: dict):
    client = boto3.client('secretsmanager')
    client.put_secret_value(SecretId=secret, SecretString=json.dumps(value))

def execute_role_create(credentials, script, param):
    conn = None
    try:
        conn = psycopg2.connect(**credentials)
        with conn.cursor() as cur:
            with open(PATH + script, 'r', encoding= 'utf-8') as file:
                query = file.read()
            logger.info(f"Executing sql file: {script}")
            cur.execute(query, param)
            username = query.split('"')[1]
        conn.commit()
    except Exception as err:
        logger.error(f"Error executing role create {err}")
        raise err
    finally:
        if conn: 
            conn.close()
    return username
        
def execute_scripts(credentials, data):
    conn = None
    try:
        conn = psycopg2.connect(**credentials)
        with conn.cursor() as cur:
            # Read each query
            for item in data:
                logger.info("Reading eact sql")
                with open(PATH + item, 'r', encoding= 'utf-8') as file:
                    query = file.read()
                logger.info(f"Executing sql file {item}")
                cur.execute(query)      
        conn.commit()
    except Exception as err:
        logger.error(f"Error executing scripts {err}")
        raise err
    finally:
        if conn: 
            conn.close()


def main():
    logger.info("Start function")
    # Load env
    env = os.environ["STAGE"]
    # Load args
    secret_db_user = sys.argv[1]
    secret_db_master = sys.argv[2]
    error = False
    data = []
    try:
        # Read config
        data, role_create = read_config(env)
    
        # If need create role      
        if role_create:
            credentials = get_secret_value(secret_db_master)
            credentials = {
                'host': credentials["host"],
                'port': credentials["port"],
                'database': credentials["dbname"],
                'user': credentials["username"],
                'password': credentials["password"],
            }
            param = str(uuid.uuid1())
            username = execute_role_create(credentials, "scripts/role_create.sql", [param])
            # update secret
            logger.info(f"update secret {secret_db_user} with username: {username}")
            value = {
                'host': credentials["host"],
                'port': credentials["port"],
                'database': credentials["database"],
                'username': username,
                'password': param,
            }
            put_secret_value(secret_db_user, value)

        # Execute regular scripts
        credentials = get_secret_value(secret_db_user)
        credentials = {
            'host': credentials["host"],
            'port': credentials["port"],
            'database': credentials["database"],
            'user': credentials["username"],
            'password': credentials["password"],
        }
        execute_scripts(credentials, data) 
    except Exception as err:
        logger.error(f"Error {err}")
        error = True
    logger.info("Finish function")
    return error


if __name__ == "__main__":
    error = main()
    if error:
        sys.exit(2)