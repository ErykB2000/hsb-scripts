#
#	Database structure
#
#	(c) 2013 Jean-Georges Valle <jejeva.bxl@gmail.com>
#	(c) 2013 Frederic Pasteleurs <frederic@askarel.be>
#	(c) 2014 Tom Behets <behets@gmail.com>
#
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
#


drop database IF EXISTS rfid_db_hsbxl;
 create database rfid_db_hsbxl;
 use rfid_db_hsbxl;

DROP TABLE IF EXISTS `logs_bell`;

CREATE TABLE `logs_bell` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `date` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=latin1;

DROP TABLE IF EXISTS `logs_door`;

CREATE TABLE `logs_door` (
  `id` int(11) unsigned NOT NULL AUTO_INCREMENT,
  `login` varchar(100) NOT NULL DEFAULT '',
  `date` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=latin1;

 create table user_roles (
  rolename varchar(10),
  can_login boolean not null,
  can_provision boolean not null,
  can_deprovision boolean not null,
  primary key (rolename)
 ) ENGINE=InnoDB CHARACTER SET utf8 COLLATE utf8_general_ci;


 create table users (
  login varchar(100),
  hash binary(60) not null,
  user_role varchar(10) not null,
  password_reset boolean not null,
  primary key(login),
  INDEX (user_role),
  CONSTRAINT fk_user_role FOREIGN KEY (user_role) REFERENCES user_roles(rolename)
 ) ENGINE=InnoDB CHARACTER SET utf8 COLLATE utf8_general_ci;


  create table tags_status (
   status_name varchar(20),
   status_is_valid boolean not null,
   primary key (status_name)
  ) ENGINE=InnoDB CHARACTER SET utf8 COLLATE utf8_general_ci;


  create table tags (
   UID varchar(100),
   status varchar(20),
    validitystart timestamp default current_timestamp,
    validityend timestamp,
   primary key (UID),
   INDEX (status),
   CONSTRAINT fk_status FOREIGN KEY (status) references tags_status(status_name)
  ) ENGINE=InnoDB CHARACTER SET utf8 COLLATE utf8_general_ci;


  create table users_vs_tags (
   user_login varchar(100),
   tag_UID varchar(100),
   primary key (user_login,tag_UID),
   INDEX (tag_UID),
   INDEX (user_login),
   constraint U_tag_UID unique (tag_UID),
   CONSTRAINT fk_user_login FOREIGN KEY (user_login) references users(login),
   CONSTRAINT fk_tag_UID FOREIGN KEY (tag_UID) references tags(UID) 
  ) ENGINE=InnoDB CHARACTER SET utf8 COLLATE utf8_general_ci;


  INSERT into tags_status values('DISABLED',FALSE);
  INSERT into tags_status values('STOLEN',FALSE);
  INSERT into tags_status values('LOST',FALSE);
  INSERT into tags_status values('ACTIVE',TRUE);
  INSERT INTO user_roles values('DESACTIVATED_USER',FALSE,FALSE,FALSE);
  INSERT INTO user_roles values('NORMAL_USER',TRUE,FALSE,FALSE);
  INSERT INTO user_roles values('NORMAL_ADMIN',TRUE,TRUE,TRUE);


  drop procedure IF EXISTS rfid_db_hsbxl.checktag;
  DELIMITER $$
  create procedure rfid_db_hsbxl.checktag (IN theTag varchar(100))
  BEGIN
   SELECT login FROM tags,tags_status,users,users_vs_tags WHERE status_name=status AND status='ACTIVE' AND login=user_login AND UID=tag_UID AND UID=theTag;
  END;
  $$
  DELIMITER ;


  drop procedure IF EXISTS rfid_db_hsbxl.getuserfromtag;
  DELIMITER $$
  create procedure rfid_db_hsbxl.getuserfromtag (IN theTag varchar(100))
  BEGIN
   SELECT user_login FROM users_vs_tags WHERE tag_UID=theTag;
  END;
  $$
  DELIMITER ;

  drop procedure IF EXISTS rfid_db_hsbxl.getflattags;
  DELIMITER $$
  create procedure rfid_db_hsbxl.getflattags ()
  BEGIN
    select uid, unix_timestamp (validitystart), unix_timestamp (validityend), 0, 0, users_vs_tags.user_login from tags, users_vs_tags where (uid=tag_uid) and ((current_timestamp < validityend) or (validityend is null)) order by user_login ;
  END;
  $$
  DELIMITER ;


  DELIMITER $$
  CREATE TRIGGER user_desactivated before update on users FOR EACH ROW 
  BEGIN
   IF NEW.user_role='DESACTIVAT' THEN
   UPDATE tags set status = 'DISABLED' where UID in (select tag_UID as UID from users_vs_tags where user_login= NEW.login);
   END IF;
   IF not NEW.user_role='DESACTIVAT' THEN
    UPDATE tags set status = 'ACTIVE' where UID in (select tag_UID as UID from users_vs_tags where user_login= NEW.login AND status = 'DISABLED');
   END IF;
  END;
  $$
  DELIMITER ;


  grant select on rfid_db_hsbxl.* to 'rfid_web_user'@'localhost' identified by 'ChangeMe';
  grant insert on rfid_db_hsbxl.tags to 'rfid_web_user'@'localhost';
  grant insert on rfid_db_hsbxl.logs_door to 'api'@'localhost';
  grant insert on rfid_db_hsbxl.logs_bell to 'api'@'localhost';
  grant insert on rfid_db_hsbxl.users to 'rfid_web_user'@'localhost';
  grant insert on rfid_db_hsbxl.users_vs_tags to 'rfid_web_user'@'localhost';
  grant update on rfid_db_hsbxl.tags to 'rfid_web_user'@'localhost';
  grant update on rfid_db_hsbxl.users to 'rfid_web_user'@'localhost';
  grant update on rfid_db_hsbxl.users_vs_tags to 'rfid_web_user'@'localhost';
  grant execute on procedure rfid_db_hsbxl.checktag to 'rfid_shell_user'@'localhost' identified by 'ChangeMe';
  grant execute on procedure rfid_db_hsbxl.getuserfromtag to 'rfid_shell_user'@'localhost';
  grant execute on procedure rfid_db_hsbxl.getflattags to 'rfid_shell_user'@'localhost';
